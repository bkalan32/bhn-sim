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
  * SAFETY. A lock, and a startup pass that recomputes the gauges from the store.
    Records live on a PersistentVolume, not an emptyDir (see the manifest).

Day 21 — the store is SQLite (store.py): incidents + an append-only timeline table, in
DATA_DIR/incidents.db. The Day 8-20 JSON files are imported on first start and renamed
*.json.imported. GET /incidents gains ?since=<epoch|ISO> for Mission Control.

Endpoints
  POST   /alertmanager           Alertmanager webhook receiver
  GET    /incidents              summary list  (?status=open|resolved  &since=<epoch|ISO>  &full=1: Day 24 KPIs)
  POST   /incidents/{id}/close   a human closes a stale ticket, with a reason (Day 24)
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
import kb
import enrich
import store

VERSION = os.getenv("APP_VERSION", "0.5")
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
CREATED = Counter("incidents_created_total", "Incidents created", ["service"])    # Day 18: by service (KPI 3)
RESOLVED = Counter("incidents_resolved_total", "Incidents resolved", ["service"])
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


def _check_id(iid: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", iid or ""):
        raise HTTPException(400, "bad incident id")
    return iid


def _load(iid: str) -> dict:
    inc = store.load(_check_id(iid))
    if inc is None:
        raise HTTPException(404, f"no incident {iid}")
    return inc


def _save(inc: dict) -> None:
    # One transaction: the incident row and the new timeline events land together or not
    # at all (store.save). The timeline is append-only — a shorter one is refused.
    store.save(inc)


def _all() -> list:
    return store.summaries()


def _open_incidents() -> list:
    return store.summaries(status="open")


def _find_open(join_key: str):
    return store.find_open(join_key)


def _refresh_open_gauge():
    OPEN.set(store.count("open"))


STORE_INFO = store.init(DATA_DIR)
log.info("store ready", extra={"extra": STORE_INFO})
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
    if kind == "hypothesis":
        # Day 17: record WHICH KB entries were offered to the model, so a grader can tell
        # "it cited kb-001" from "kb-001 was never in the prompt" (docs/ai-eval.md Eval 8).
        meta["kb_matches"] = [{"id": m["id"], "score": m.get("score")} for m in ai.kb_matches(inc)]
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
                CREATED.labels(service=service).inc()
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
                RESOLVED.labels(service=service).inc()
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
                "resolved_at_iso", "duration_min", "closed_by_human")


def _since(v):
    """?since= accepts an epoch (1790182530) or an ISO time (2026-09-23T16:00:00Z)."""
    if v is None or v == "":
        return None
    try:
        return float(v)
    except ValueError:
        ts = _parse_ts(v)
        if ts is None:
            raise HTTPException(400, "since: an epoch or an ISO-8601 time")
        return ts


# Day 24: ?full=1 is mission control's KPI page — every field a KPI needs (first_alert_at, the
# timeline's drill notes, closed_by_human) and none of the heavy ones (drafts, context).
HEAVY_KEYS = ("ai_open_draft", "ai_resolution_draft", "ai_hypothesis", "context", "context_meta", "ai_meta", "groups")


@app.get("/incidents")
def list_incidents(status: str | None = None, since: str | None = None, full: bool = False):
    incs = store.summaries(status=status or None, since=_since(since))
    if full:
        out = []
        for i in incs:
            rec = store.load(i["id"]) or i
            out.append({k: v for k, v in rec.items() if k not in HEAVY_KEYS})
        return out
    return [{k: i.get(k) for k in SUMMARY_KEYS} for i in incs]


@app.post("/incidents/{iid}/close")
async def close_incident(iid: str, request: Request):
    """Day 24: a human closes a ticket whose 'resolved' webhook will never come (a restart lost it).
    Mission control's close_incident action checks first that none of its alerts still fires. The
    record says so for ever: closed_by_human {by, reason}, and the KPI page leaves it out of MTTR —
    its duration is how long nobody noticed, not how long anything was broken. No resolution draft:
    the AI would be summarising a gap in the record, not an incident."""
    body = await request.json() or {}
    by, reason = str(body.get("by") or "").strip()[:60], str(body.get("reason") or "").strip()[:300]
    if not by or len(reason) < 10:
        raise HTTPException(400, "close needs 'by' and a 'reason' of at least 10 characters")
    with _lock:
        inc = _load(iid)
        if inc.get("status") != "open":
            raise HTTPException(409, f"{iid} is already {inc.get('status')}")
        now = _now()
        inc["status"] = "resolved"
        inc["resolved_at"], inc["resolved_at_iso"] = now, _iso(now)
        inc["duration_min"] = round((now - inc["opened_at"]) / 60, 1)
        inc["closed_by_human"] = {"by": by, "reason": reason, "at_iso": _iso(now)}
        inc["timeline"].append(_event("incident_closed", by=by, reason=reason, duration_min=inc["duration_min"]))
        RESOLVED.labels(service=inc.get("service")).inc()
        _save(inc)
        _refresh_open_gauge()
    log.info("incident closed by a human", extra={"extra": {"incident": iid, "by": by}})
    return {"ok": True, "incident": iid, "status": "resolved", "closed_by_human": inc["closed_by_human"]}


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


@app.get("/tools/deploys")
def tool_deploys(hours: int = 24):
    """Day 18: deploys and rollbacks for every service in the last `hours`, from the same
    Grafana-annotation collector the ticket enrichment uses — for the daily report."""
    out = {}
    for svc in ("activation", "egift", "settlement", "incident-bot", "remediator"):
        rows, meta = enrich.recent_deploys(svc, time.time(), hours=max(1, min(int(hours), 168)))
        out[svc] = [r for r in rows if "text" in r]
        if not meta.get("ok"):
            out[svc] = [{"error": meta.get("error", "deploy lookup unavailable")}]
    return {"hours": hours, "deploys": out}


@app.get("/ai")
def ai_status():
    return {"enabled": ai.enabled(), **ai.describe(), "enrich": {"enabled": ENRICH_ENABLED, **enrich.configured()},
            "kb": _kb_status()}


def _kb_status():
    """Day 17: is the team's memory mounted, and does it parse?"""
    try:
        entries = kb.load()
        return {"dir": kb.KB_DIR, "entries": [e["id"] for e in entries], "ok": True}
    except Exception as e:  # noqa: BLE001
        return {"dir": kb.KB_DIR, "entries": [], "ok": False, "error": f"{type(e).__name__}: {e}"}


@app.get("/kb/search")
def kb_search(q: str):
    """Day 17: what the bot would match for a bag of symptoms — the copilot and 172 --search use the same scorer."""
    try:
        return [{"id": e["id"], "title": e["title"], "score": e["score"], "learned_from": e["learned_from"], "tier": e["tier"]}
                for e in kb.search(q)]
    except Exception as e:  # noqa: BLE001
        return {"error": f"{type(e).__name__}: {e}"}


# ------------------------------------------------------------ reports (Day 18) ---
# The daily ops report is generated OUTSIDE the bot (tools/daily_report.py, on a Jenkins
# schedule) and stored here, next to the incidents it summarises, so "what did the platform
# tell me on the 12th" has one answer. Ten lines, as the PDF says; the same atomic-write rule.
def _report_path(day: str) -> str:
    if not re.match(r"^\d{4}-\d{2}-\d{2}(-[a-z0-9-]{1,24})?$", day):
        raise HTTPException(400, "day must be YYYY-MM-DD or YYYY-MM-DD-<slug> (a re-run after a drill)")
    d = os.path.join(DATA_DIR, "reports")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, f"{day}.json")


@app.post("/reports")
async def put_report(request: Request):
    body = await request.json()
    day = str(body.get("day", "")); text = str(body.get("text", ""))
    if not text.strip():
        raise HTTPException(400, "text is required")
    rec = {"day": day, "text": text, "words": len(text.split()), "stored_at_iso": _iso(_now()),
           "model": body.get("model"), "data": body.get("data"), "grade": body.get("grade")}
    p = _report_path(day); tmp = p + ".tmp"
    with _lock:
        with open(tmp, "w") as f:
            json.dump(rec, f, indent=2)
        os.replace(tmp, p)
    log.info("report stored", extra={"extra": {"day": day, "words": rec["words"]}})
    return {"ok": True, "day": day, "words": rec["words"]}


@app.get("/reports")
def list_reports():
    d = os.path.join(DATA_DIR, "reports")
    if not os.path.isdir(d):
        return []
    out = []
    for name in sorted(os.listdir(d), reverse=True):
        if name.endswith(".json"):
            with open(os.path.join(d, name)) as f:
                r = json.load(f)
            out.append({"day": r.get("day"), "words": r.get("words"), "stored_at_iso": r.get("stored_at_iso"), "model": r.get("model")})
    return out


@app.get("/reports/{day}")
def get_report(day: str):
    p = _report_path(day)
    if not os.path.exists(p):
        raise HTTPException(404, f"no report for {day}")
    with open(p) as f:
        return json.load(f)


@app.delete("/incidents/{iid}")
def delete_incident(iid: str):
    # Lab only. A real ticketing system never deletes; it closes with a reason.
    with _lock:
        if not store.delete(_check_id(iid)):
            raise HTTPException(404, f"no incident {iid}")
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
    try:
        store.ping()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"store not writable: {e}")
    return {"status": "ready", "join": INCIDENT_JOIN, "open": store.count("open"), "store": "sqlite"}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
