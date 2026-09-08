"""
incident-bot — the ticketing layer, built by hand.

Alertmanager POSTs one webhook per *notification group*. This service turns those
webhooks into incident records: it opens an incident when a group starts firing,
appends every later webhook to an append-only timeline, and closes the incident when
Alertmanager says the group has resolved. Everything the AI work on Days 9 and 10
reads comes from these records.

Differences from the PDF's version (details in CORRECTIONS-DAY8.md):

  * JOIN KEY. The PDF keys incidents on Alertmanager's groupKey. But the group key
    contains the *route* that matched, so its own severity sub-route puts critical and
    warning alerts for the same outage into two groups — and therefore two incidents.
    Here the default join is the service label (INCIDENT_JOIN=service): one outage,
    one incident. Each group is still tracked inside the incident, so the incident
    only resolves when *every* group has resolved.
  * SEVERITY. The PDF does max("critical", "warning") — string comparison, which
    always says "warning". Ranked here.
  * TIMES. Alert startsAt is recorded (that is when Prometheus saw it), not only the
    time the webhook arrived. Day 10's time-to-detect needs it. ISO strings sit next to
    every epoch so a human — or a model — can read the timeline.
  * SAFETY. Atomic file writes, a lock, and a startup pass that recomputes the gauges
    from disk. Records live on a PersistentVolume, not an emptyDir (see the manifest).

Endpoints
  POST   /alertmanager           Alertmanager webhook receiver
  GET    /incidents              summary list  (?status=open|resolved)
  GET    /incidents/{id}         full record with timeline
  POST   /incidents/{id}/note    {"text": "..."} — the bridge scribe (Day 9)
  POST   /incidents/{id}/draft   ?kind=open|resolved|hypothesis — (re)generate an AI draft (Day 9/10)
  POST   /incidents/{id}/enrich  re-run the context collectors on a record (Day 10)
  GET    /enrich/test?service=x  run the collectors now and return what they see (Day 10)
  POST   /tools/search_logs      {"spl": "...", "earliest": "-30m"} — validated, READ-ONLY Splunk search (Day 11)
  DELETE /incidents/{id}         lab convenience, used by the smoke test
  GET    /healthz  /readyz  /metrics  /ai

Day 9 — AI drafts. When an incident opens or resolves, ai.py drafts the internal summary,
stakeholder update and review skeleton and the bot attaches them as ai_open_draft /
ai_resolution_draft. The call runs in a BACKGROUND THREAD, never inside the webhook
request: an LLM call takes 5-60s, Alertmanager would time out and retry (duplicate
processing), and — worse — a blocking call inside an `async def` handler freezes this
whole process, health probes included, until it returns. (CORRECTIONS-DAY9.md B1)
The AI is an enhancement layered on a system that works without it.

Day 10 — context enrichment and a diagnosis. In the same background thread, BEFORE the
open draft: enrich.py fetches current metrics, recent deploys and top log reasons and
attaches them as `context`; then the open draft; then ai.hypothesize() writes a
diagnosis (what we know / most likely cause / alternative / next checks / confidence)
as `ai_hypothesis`. Diagnosis only, never remediation — that line is the central safety
boundary of AI operations, crossed deliberately on a later day, not by accident here.

Day 11 — one read-only tool for the copilot. tools/copilot.py runs on your laptop, which is
not on the platform network and holds no Splunk credential; the bot is and does. So the
bot lends its eyes: POST /tools/search_logs runs a validated SPL search (side-effect
commands refused, time window a parameter, results capped) and nothing else. The
copilot's other tools (Prometheus, kubectl, this bot's records) go through YOUR
kubeconfig, so the permission boundary is: the tool allow-list, then RBAC.
"""

import datetime as _dt
import json
import logging
import os
import re
import sys
import threading
import time
import uuid

from fastapi import FastAPI, HTTPException, Request
from starlette.concurrency import run_in_threadpool
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

import ai
import enrich

VERSION = os.getenv("APP_VERSION", "0.4")
ENRICH_ENABLED = os.getenv("ENRICH_ENABLED", "true").strip().lower() != "false"
DATA_DIR = os.getenv("DATA_DIR", "/data")
INCIDENT_JOIN = os.getenv("INCIDENT_JOIN", "service").strip().lower()   # service | group
os.makedirs(DATA_DIR, exist_ok=True)

app = FastAPI(title="incident-bot", version=VERSION)
_lock = threading.Lock()

SEV_RANK = {"critical": 3, "warning": 2, "info": 1, "none": 0}


# --------------------------------------------------------------- logging ----
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": _dt.datetime.fromtimestamp(record.created, tz=_dt.timezone.utc)
                  .isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname, "service": "incident-bot", "version": VERSION,
            "msg": record.getMessage(),
        }
        extra = getattr(record, "extra", None)
        if isinstance(extra, dict):
            payload.update(extra)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(JsonFormatter())
log = logging.getLogger("incident-bot")
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
log.addHandler(_h)
log.propagate = False


# --------------------------------------------------------------- metrics ----
CREATED = Counter("incidents_created_total", "Incidents created")
RESOLVED = Counter("incidents_resolved_total", "Incidents resolved")
OPEN = Gauge("incidents_open", "Currently open incidents")
WEBHOOKS = Counter("alertmanager_webhooks_total", "Webhooks received from Alertmanager", ["status"])
LAST_DURATION = Gauge("incident_last_duration_minutes", "Duration of the most recently resolved incident")
AI_DRAFTS = Counter("ai_drafts_total", "AI drafts attempted", ["kind", "outcome"])
AI_LATENCY = Histogram("ai_draft_latency_seconds", "AI draft call latency", ["kind"],
                       buckets=[0.5, 1, 2, 5, 10, 20, 40, 60, 120])
ENRICH = Counter("enrich_collector_total", "Context collector runs", ["collector", "outcome"])
ENRICH_LATENCY = Histogram("enrich_latency_seconds", "Whole enrichment latency",
                           buckets=[0.5, 1, 2, 5, 10, 20, 40])
TOOL_CALLS = Counter("bot_tool_calls_total", "Read-only tool calls served for the copilot (Day 11)", ["tool", "outcome"])
BUILD_INFO = Gauge("incident_bot_build_info", "Build metadata", ["version"])
BUILD_INFO.labels(version=VERSION).set(1)


# --------------------------------------------------------------- storage ----
def _now():
    return time.time()


def _iso(ts: float) -> str:
    return _dt.datetime.fromtimestamp(ts, tz=_dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _path(iid: str) -> str:
    if "/" in iid or ".." in iid:
        raise HTTPException(400, "bad incident id")
    return os.path.join(DATA_DIR, f"{iid}.json")


def _load(iid: str) -> dict:
    p = _path(iid)
    if not os.path.exists(p):
        raise HTTPException(404, f"no incident {iid}")
    with open(p) as f:
        return json.load(f)


def _save(inc: dict) -> None:
    # Atomic: a crash mid-write must not leave a half-written record for the next
    # webhook to choke on.
    p = _path(inc["id"])
    tmp = f"{p}.tmp"
    with open(tmp, "w") as f:
        json.dump(inc, f, indent=2)
    os.replace(tmp, p)


def _all() -> list:
    out = []
    for name in os.listdir(DATA_DIR):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(DATA_DIR, name)) as f:
                out.append(json.load(f))
        except Exception as e:  # noqa: BLE001 — one bad file must not hide the rest
            log.error("unreadable incident file", extra={"extra": {"file": name, "error": str(e)}})
    return sorted(out, key=lambda i: i.get("opened_at", 0), reverse=True)


def _open_incidents() -> list:
    return [i for i in _all() if i.get("status") == "open"]


def _find_open(join_key: str):
    for inc in _open_incidents():
        if inc.get("join_key") == join_key:
            return inc
    return None


def _refresh_open_gauge():
    OPEN.set(len(_open_incidents()))


_refresh_open_gauge()


# ---------------------------------------------------------------- helpers ---
def _parse_ts(s):
    """Alertmanager sends RFC3339 with nanoseconds; Python wants microseconds."""
    if not s or s.startswith("0001-"):
        return None
    try:
        s = s.replace("Z", "+00:00")
        s = re.sub(r"\.(\d{1,6})\d*", lambda m: "." + m.group(1).ljust(6, "0"), s)
        return _dt.datetime.fromisoformat(s).timestamp()
    except Exception:  # noqa: BLE001
        return None


def _summarise_alerts(alerts: list) -> list:
    out = []
    for a in alerts:
        labels, ann = a.get("labels", {}), a.get("annotations", {})
        out.append({
            "name": labels.get("alertname"),
            "severity": labels.get("severity", "none"),
            "service": labels.get("service"),
            "status": a.get("status"),
            "summary": ann.get("summary"),
            "description": ann.get("description"),
            "runbook": ann.get("runbook"),
            "starts_at": _parse_ts(a.get("startsAt")),
            "starts_at_iso": a.get("startsAt"),
            "ends_at_iso": a.get("endsAt") if a.get("status") == "resolved" else None,
        })
    return out


def _max_severity(names) -> str:
    best = "none"
    for s in names:
        if SEV_RANK.get(s or "none", 0) > SEV_RANK[best]:
            best = s
    return best


def _event(kind: str, **fields) -> dict:
    ts = _now()
    return {"ts": ts, "ts_iso": _iso(ts), "event": kind, **fields}


# --------------------------------------------------------------- AI drafts --
DRAFT_FIELD = {"open": "ai_open_draft", "resolved": "ai_resolution_draft", "hypothesis": "ai_hypothesis"}
DRAFT_FN = {"open": ai.summarize_open, "resolved": ai.summarize_resolved, "hypothesis": ai.hypothesize}


def _enrich(iid: str):
    """Attach the three lookups to the record. Never raises; every collector degrades."""
    try:
        inc = _load(iid)
    except HTTPException:
        return
    t0 = time.perf_counter()
    ctx, meta = enrich.enrich(inc.get("service"), since_ts=inc.get("first_alert_at") or inc.get("opened_at"))
    ENRICH_LATENCY.observe(time.perf_counter() - t0)
    for name, m in meta.items():
        ENRICH.labels(collector=name, outcome="ok" if m.get("ok") else "error").inc()
    with _lock:
        try:
            inc = _load(iid)
        except HTTPException:
            return
        inc["context"] = ctx
        inc.setdefault("context_meta", {}).update(meta)
        inc["timeline"].append(_event("context_attached",
                                      collectors={k: ("ok" if v.get("ok") else "error") for k, v in meta.items()},
                                      latency_ms=round((time.perf_counter() - t0) * 1000)))
        _save(inc)
    log.info("context attached", extra={"extra": {"incident": iid, **{f"{k}_ok": v.get("ok") for k, v in meta.items()}}})


def _open_pipeline(iid: str):
    """What happens in the background when a ticket opens: enrich -> summary -> diagnosis.
    Order matters: the summary and the hypothesis both read the context."""
    if ENRICH_ENABLED:
        _enrich(iid)
    _draft(iid, "open")
    _draft(iid, "hypothesis")


def _draft(iid: str, kind: str):
    """Generate a draft and attach it to the record. Runs in a background thread."""
    try:
        inc = _load(iid)
    except HTTPException:
        return
    text, meta = DRAFT_FN[kind](inc)
    AI_DRAFTS.labels(kind=kind, outcome="ok" if meta.get("ok") else "error").inc()
    if meta.get("latency_ms") is not None:
        AI_LATENCY.labels(kind=kind).observe(meta["latency_ms"] / 1000)
    with _lock:
        try:
            inc = _load(iid)                       # re-read: webhooks may have landed meanwhile
        except HTTPException:
            return
        inc[DRAFT_FIELD[kind]] = text
        inc.setdefault("ai_meta", {})[kind] = meta
        inc["timeline"].append(_event("ai_draft_attached", draft=kind, ok=meta.get("ok", False),
                                      model=meta.get("model"), latency_ms=meta.get("latency_ms")))
        _save(inc)
    log.info("ai draft attached", extra={"extra": {"incident": iid, "kind": kind, **{k: v for k, v in meta.items() if k != "kind"}}})


def _schedule_draft(iid: str, kind: str):
    if not ai.enabled():
        # Attach the reason synchronously so the record says WHY there is no draft.
        # Enrichment still runs (it needs no AI) — context is useful to a human too.
        with _lock:
            inc = _load(iid)
            for k in ((kind, "hypothesis") if kind == "open" else (kind,)):
                inc[DRAFT_FIELD[k]] = "(AI draft unavailable: no provider configured)"
            _save(inc)
        AI_DRAFTS.labels(kind=kind, outcome="disabled").inc()
        if kind == "open" and ENRICH_ENABLED:
            threading.Thread(target=_enrich, args=(iid,), daemon=True, name=f"enrich-{iid}").start()
        return
    target = _open_pipeline if kind == "open" else _draft
    args = (iid,) if kind == "open" else (iid, kind)
    threading.Thread(target=target, args=args, daemon=True, name=f"draft-{kind}-{iid}").start()


# --------------------------------------------------------------- receiver ---
@app.post("/alertmanager")
async def receive(request: Request):
    payload = await request.json()
    status = payload.get("status", "firing")          # firing | resolved
    group_key = payload.get("groupKey", "")
    alerts = _summarise_alerts(payload.get("alerts", []))
    WEBHOOKS.labels(status=status).inc()
    if not alerts:
        return {"ok": True, "note": "empty webhook"}

    service = (payload.get("groupLabels", {}).get("service")
               or next((a["service"] for a in alerts if a.get("service")), None))
    join_key = service if (INCIDENT_JOIN == "service" and service) else group_key

    opened_now = resolved_now = False
    with _lock:
        inc = _find_open(join_key)

        if status == "firing":
            if not inc:
                opened_now = True
                opened = _now()
                first_seen = min((a["starts_at"] for a in alerts if a.get("starts_at")), default=opened)
                iid = f"INC-{int(opened)}-{uuid.uuid4().hex[:4]}"
                inc = {
                    "id": iid, "status": "open", "service": service, "join_key": join_key,
                    "severity": _max_severity(a["severity"] for a in alerts),
                    "opened_at": opened, "opened_at_iso": _iso(opened),
                    # When Prometheus first saw the condition — before group_wait, before
                    # the webhook. This is "time detected" for the KPI table on Day 10.
                    "first_alert_at": first_seen, "first_alert_at_iso": _iso(first_seen),
                    "alerts": [], "groups": {}, "timeline": [],
                }
                CREATED.inc()
                log.info("incident opened", extra={"extra": {
                    "incident": iid, "incident_service": service, "severity": inc["severity"],
                    "alerts": [a["name"] for a in alerts]}})
            inc["groups"][group_key] = "firing"
            inc["alerts"] = sorted(set(inc["alerts"]) | {a["name"] for a in alerts if a.get("name")})
            inc["severity"] = _max_severity([inc["severity"]] + [a["severity"] for a in alerts])
            inc["timeline"].append(_event("alerts_firing", group_key=group_key, alerts=alerts))

        else:  # resolved
            if not inc:
                log.info("resolved webhook for no open incident", extra={"extra": {
                    "incident_service": service, "alerts": [a["name"] for a in alerts]}})
                return {"ok": True, "note": "resolved for unknown incident"}
            inc["groups"][group_key] = "resolved"
            inc["timeline"].append(_event("alerts_resolved", group_key=group_key, alerts=alerts))
            if all(v == "resolved" for v in inc["groups"].values()):
                resolved_now = True
                inc["status"] = "resolved"
                inc["resolved_at"] = _now()
                inc["resolved_at_iso"] = _iso(inc["resolved_at"])
                inc["duration_min"] = round((inc["resolved_at"] - inc["opened_at"]) / 60, 1)
                inc["timeline"].append(_event("incident_resolved", duration_min=inc["duration_min"]))
                RESOLVED.inc()
                LAST_DURATION.set(inc["duration_min"])
                log.info("incident resolved", extra={"extra": {
                    "incident": inc["id"], "incident_service": service, "duration_min": inc["duration_min"]}})

        _save(inc)
        _refresh_open_gauge()
    # Outside the lock, outside the request's critical path.
    if opened_now:
        _schedule_draft(inc["id"], "open")
    if resolved_now:
        _schedule_draft(inc["id"], "resolved")
    return {"ok": True, "incident": inc["id"], "status": inc["status"]}


# ------------------------------------------------------------------ reads ---
SUMMARY_KEYS = ("id", "status", "service", "severity", "alerts", "opened_at_iso",
                "resolved_at_iso", "duration_min")


@app.get("/incidents")
def list_incidents(status: str | None = None):
    incs = _all()
    if status:
        incs = [i for i in incs if i.get("status") == status]
    return [{k: i.get(k) for k in SUMMARY_KEYS} for i in incs]


@app.get("/incidents/{iid}")
def get_incident(iid: str):
    return _load(iid)


# ------------------------------------------------------------------ notes ---
@app.post("/incidents/{iid}/note")
async def add_note(iid: str, request: Request):
    body = await request.json()
    text = (body or {}).get("text", "").strip()
    if not text:
        raise HTTPException(400, "note needs a non-empty 'text'")
    with _lock:
        inc = _load(iid)
        inc["timeline"].append(_event("note", text=text, author=(body or {}).get("author", "responder")))
        _save(inc)
    log.info("note added", extra={"extra": {"incident": iid}})
    return {"ok": True, "incident": iid, "events": len(inc["timeline"])}


@app.post("/incidents/{iid}/draft")
def redraft(iid: str, kind: str = "open", wait: bool = False):
    """(Re)generate a draft — after notes were added, after a prompt change, or on a
    record written before the AI existed. wait=true blocks until done (tools/inc.py)."""
    if kind not in DRAFT_FIELD:
        raise HTTPException(400, "kind must be open, resolved or hypothesis")
    _load(iid)
    if not ai.enabled():
        _schedule_draft(iid, kind)
        return {"ok": False, "incident": iid, "kind": kind, "note": "no AI provider configured"}
    if wait:
        _draft(iid, kind)
        return {"ok": True, "incident": iid, "kind": kind, "draft": _load(iid).get(DRAFT_FIELD[kind])}
    threading.Thread(target=_draft, args=(iid, kind), daemon=True).start()
    return {"ok": True, "incident": iid, "kind": kind, "note": "drafting in background; poll the record"}


@app.post("/incidents/{iid}/enrich")
def reenrich(iid: str, wait: bool = True):
    """Re-run the collectors on a record (e.g. after fixing a collector's config)."""
    _load(iid)
    if wait:
        _enrich(iid)
        return {"ok": True, "incident": iid, "context": _load(iid).get("context")}
    threading.Thread(target=_enrich, args=(iid,), daemon=True).start()
    return {"ok": True, "incident": iid, "note": "enriching in background"}


@app.get("/enrich/test")
def enrich_test(service: str = "activation"):
    """What would the collectors see right now? Used by scripts/100-enrich-config.sh."""
    ctx, meta = enrich.enrich(service, since_ts=time.time())
    return {"context": ctx, "collectors": meta}


@app.post("/tools/search_logs")
async def tool_search_logs(request: Request):
    """Day 11. Read-only by construction (enrich.validate_spl). Returns rows + meta; never 5xx
    for a bad search — the copilot needs the *reason* as a tool result, not an exception.
    The body is read with request.json() (kubectl --raw sends no JSON content-type, and
    FastAPI's Body() parser rejects that with a 422); the Splunk call, which can take 20 s,
    runs in a threadpool so it never blocks the event loop (CORRECTIONS-DAY9 B1)."""
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        body = {}
    body = body or {}
    out = await run_in_threadpool(enrich.search_logs, str(body.get("spl", "")),
                                  str(body.get("earliest", "-30m") or "-30m"), body.get("limit", 50))
    TOOL_CALLS.labels(tool="search_logs", outcome="ok" if out["meta"].get("ok") else "error").inc()
    log.info("tool search_logs", extra={"extra": {"ok": out["meta"].get("ok"), "count": out["count"],
                                                  "latency_ms": out["meta"].get("latency_ms"), "spl": out["spl"][:200]}})
    return out


@app.get("/ai")
def ai_status():
    return {"enabled": ai.enabled(), **ai.describe(), "enrich": {"enabled": ENRICH_ENABLED, **enrich.configured()}}


@app.delete("/incidents/{iid}")
def delete_incident(iid: str):
    # Lab only. A real ticketing system never deletes; it closes with a reason.
    p = _path(iid)
    if not os.path.exists(p):
        raise HTTPException(404, f"no incident {iid}")
    with _lock:
        os.remove(p)
        _refresh_open_gauge()
    return {"ok": True, "deleted": iid}


# ----------------------------------------------------------------- health ---
@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": VERSION}


@app.get("/readyz")
def readyz():
    # Ready means "can persist": if the volume is gone, refuse traffic so Alertmanager
    # retries later instead of dropping the webhook into a black hole.
    if not os.access(DATA_DIR, os.W_OK):
        raise HTTPException(503, f"{DATA_DIR} not writable")
    return {"status": "ready", "join": INCIDENT_JOIN, "open": len(_open_incidents())}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
