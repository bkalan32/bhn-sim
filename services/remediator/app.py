"""
remediator — auto-remediation with the safety on. Day 12.

Subscribes to the same Alertmanager webhook fan-out as the incident bot. For every firing
group it looks for a SIGNATURE (signatures.py). Tier 1 runs now and notifies after; tier 2
prepares the action and waits for a capability token; no signature = tier 3 = "human
required" on the ticket, nothing else.

Every action — proposed, approved, declined, executed, failed, skipped — is written to the
incident timeline through the bot, prefixed [remediator]. During a bridge, "what has the
automation already done?" must have an instant answer.

Differences from the PDF's remediator (CORRECTIONS-DAY12.md):
  * the webhook handler never executes anything inline: actions run in a background
    thread (a rollback takes 30-60 s; Alertmanager would time out and retry — Day 9's rule)
  * notes go to the incident FOR THIS SERVICE, not "the first open incident"; and the bot
    may not have opened it yet when the fan-out arrives, so the lookup waits for it
  * delete_pod deletes THE pod the alert names, after checking it really is in
    CrashLoopBackOff — not "any pod with more than 3 restarts" parsed from column 4
  * cooldown per signature (10 min), bounded retry (once), token expiry (30 min),
    per-incident dedupe of proposals and of the tier-3 note
  * kubectl runs as an argv list, never through a shell; the ServiceAccount's Role is the
    real boundary (k8s/remediator.yaml)
  * DRY_RUN=true makes every action a no-op that reports what it would have run — the
    unit tests use it; so can you

Endpoints
  POST /alertmanager        webhook (firing and resolved)
  GET  /pending             tier-2 proposals waiting for a human
  POST /approve/{token}     execute a proposal (body optional: {"by": "name"})
  POST /decline/{token}     drop a proposal
  GET  /actions             everything this process has done, newest first (in memory)
  GET  /signatures          the policy, as loaded
  GET  /healthz  /readyz  /metrics
"""

import datetime as _dt
import json
import logging
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from starlette.concurrency import run_in_threadpool

from signatures import SIGNATURES, validate

VERSION = os.getenv("APP_VERSION", "0.1")
NS = os.getenv("NAMESPACE", "payments")
BOT = os.getenv("BOT_URL", "http://incident-bot.payments:8020").rstrip("/")
KUBECTL = os.getenv("KUBECTL", "kubectl")
DRY_RUN = os.getenv("DRY_RUN", "false").strip().lower() == "true"
TOKEN_TTL_S = int(os.getenv("TOKEN_TTL_S", "1800"))
INCIDENT_WAIT_S = int(os.getenv("INCIDENT_WAIT_S", "60"))
GRAFANA = os.getenv("GRAFANA_URL", "http://kps-grafana.monitoring").rstrip("/")
GRAFANA_TOKEN = os.getenv("GRAFANA_TOKEN", "").strip()       # Editor SA token, secret/remediator-config
validate()

app = FastAPI(title="remediator", version=VERSION)
_lock = threading.Lock()
PENDING = {}        # token -> proposal   (in memory: a restart forgets proposals; noted lab limitation)
LAST_ACTION = {}    # signature id -> epoch of the last executed/attempted action (cooldown)
NOTED_T3 = set()    # incident ids that already carry the "human required" note
PROPOSED = set()    # (signature, incident) already proposed
HISTORY = []        # newest first, capped


# --------------------------------------------------------------- logging ----
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {"ts": _dt.datetime.fromtimestamp(record.created, tz=_dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
                   "level": record.levelname, "service": "remediator", "version": VERSION, "msg": record.getMessage()}
        extra = getattr(record, "extra", None)
        if isinstance(extra, dict):
            payload.update(extra)
        return json.dumps(payload, separators=(",", ":"))


_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(JsonFormatter())
log = logging.getLogger("remediator")
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
log.addHandler(_h)
log.propagate = False


# --------------------------------------------------------------- metrics ----
ACTIONS = Counter("remediation_actions_total", "Remediation actions", ["signature", "mode", "result"])
PENDING_G = Gauge("remediation_pending", "Tier-2 proposals awaiting a human")
WEBHOOKS = Counter("remediator_webhooks_total", "Webhooks received", ["status"])
BUILD_INFO = Gauge("remediator_build_info", "Build metadata", ["version"])
BUILD_INFO.labels(version=VERSION).set(1)


def _now():
    return time.time()


def _iso(ts=None):
    return _dt.datetime.fromtimestamp(ts or _now(), tz=_dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _record(entry):
    entry = {"at_iso": _iso(), **entry}
    with _lock:
        HISTORY.insert(0, entry)
        del HISTORY[200:]
    log.info("remediation", extra={"extra": entry})
    return entry


# --------------------------------------------------------------- the bot ----
def _bot(method, path, body=None, timeout=5):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BOT + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"null")


def _incident_for(service, wait_s=INCIDENT_WAIT_S):
    """The OPEN incident for this service. The fan-out delivers the webhook to the bot and
    to us at the same moment, so the ticket may not exist yet: wait for it (briefly)."""
    deadline = _now() + wait_s
    while True:
        try:
            for i in _bot("GET", "/incidents?status=open") or []:
                if i.get("service") == service:
                    return i["id"]
        except Exception as e:  # noqa: BLE001
            log.warning("bot unreachable", extra={"extra": {"error": str(e)}})
        if _now() >= deadline:
            return None
        time.sleep(3)


def _note(iid, text):
    if not iid:
        log.warning("no incident to annotate", extra={"extra": {"text": text[:120]}})
        return False
    try:
        _bot("POST", f"/incidents/{iid}/note", {"text": f"[remediator] {text}", "author": "remediator"})
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("note failed", extra={"extra": {"incident": iid, "error": str(e)}})
        return False


def _recent_deploy_minutes(service, within_min):
    """Any DEPLOY (not rollback) of `service` in the last `within_min` minutes? Returns the
    age in minutes of the newest one, else None. Source: the bot's deploy collector (Grafana
    annotations written by the pipeline) — the same truth the Day 10 diagnosis uses."""
    try:
        d = _bot("GET", f"/enrich/test?service={urllib.parse.quote(service)}", timeout=30)
    except Exception as e:  # noqa: BLE001
        log.warning("deploy lookup failed", extra={"extra": {"error": str(e)}})
        return None
    changes = [e for e in (d.get("context", {}).get("recent_deploys") or [])
               if e.get("kind") in ("deploy", "rollback") and isinstance(e.get("minutes_before_first_alert"), (int, float))]
    changes.sort(key=lambda e: e["minutes_before_first_alert"])          # newest first
    if not changes or changes[0]["minutes_before_first_alert"] > within_min:
        return None
    if changes[0]["kind"] == "rollback":
        # The newest change is already a rollback (the pipeline's Verify did its job, or a
        # human did). Proposing another would undo the undo. Not a match.
        return None
    return changes[0]["minutes_before_first_alert"]


# --------------------------------------------------------------- kubectl ----
def _run(argv, timeout=200, keep=1500):
    """kubectl as an argv list. Never a shell. DRY_RUN reports instead of acting.
    Output is trimmed to its last `keep` chars so a log dump cannot flood a note —
    pass keep=None when the output is a document you will PARSE (a pod as JSON is far
    longer than 1,500 chars; the tail of a JSON document is not JSON — B11)."""
    cmd = [KUBECTL, "-n", NS] + list(argv)
    if DRY_RUN:
        return True, "dry-run: " + " ".join(cmd)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"timeout after {timeout}s: {' '.join(cmd)}"
    except FileNotFoundError:
        return False, f"{KUBECTL} not found"
    if out.returncode != 0:
        return False, (out.stdout + out.stderr).strip()[-(keep or 1500):]
    text = out.stdout if keep is None else (out.stdout + out.stderr).strip()[-keep:]
    return True, text


def _crashlooping_status(cs):
    """A container is crash-looping if it is waiting in CrashLoopBackOff OR it has restarted
    3+ times and its last exit was non-zero. The second clause matters: a container that
    exits instantly is mostly TERMINATED and only briefly in CrashLoopBackOff, so a check
    that insists on the waiting state refuses a real crash-loop as "stale" (B10)."""
    w = (cs.get("state") or {}).get("waiting") or {}
    if w.get("reason") == "CrashLoopBackOff":
        return f"{cs.get('name')} restarts={cs.get('restartCount')} reason=CrashLoopBackOff"
    last = (cs.get("lastState") or {}).get("terminated") or {}
    cur = (cs.get("state") or {}).get("terminated") or {}
    code = cur.get("exitCode", last.get("exitCode"))
    if (cs.get("restartCount") or 0) >= 3 and code not in (None, 0):
        return f"{cs.get('name')} restarts={cs.get('restartCount')} last exit code {code}"
    return None


def _pod_crashlooping(pod):
    """Verify the condition before acting: is THIS pod crash-looping right now?"""
    ok, out = _run(["get", "pod", pod, "-o", "json"], timeout=20, keep=None)
    if DRY_RUN:
        return True, "dry-run"
    if not ok:
        return False, out
    try:
        for cs in json.loads(out).get("status", {}).get("containerStatuses", []):
            why = _crashlooping_status(cs)
            if why:
                return True, why
        return False, "no container in CrashLoopBackOff or with 3+ failed restarts"
    except Exception as e:  # noqa: BLE001
        return False, f"cannot parse pod: {e}"


def _job_outcome(job, timeout_s=200):
    """Wait for a Job to finish. Returns (ok, detail)."""
    if DRY_RUN:
        return True, "dry-run: job would be awaited"
    deadline = _now() + timeout_s
    while _now() < deadline:
        ok, out = _run(["get", "job", job, "-o", "jsonpath={.status.conditions[*].type}"], timeout=20)
        if ok and "Complete" in out:
            _, logs = _run(["logs", f"job/{job}", "--tail=2"], timeout=20)
            return True, logs[-300:] or "completed"
        if ok and "Failed" in out:
            _, logs = _run(["logs", f"job/{job}", "--tail=2"], timeout=20)
            return False, f"job Failed. {logs[-300:]}"
        time.sleep(5)
    return False, f"job {job} did not finish within {timeout_s}s"


def _grafana_annotate(tag, service, text):
    if not GRAFANA_TOKEN:
        return False
    try:
        body = json.dumps({"tags": [tag, service], "text": text}).encode()
        req = urllib.request.Request(f"{GRAFANA}/api/annotations", data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": f"Bearer {GRAFANA_TOKEN}"})
        with urllib.request.urlopen(req, timeout=10):
            return True
    except Exception as e:  # noqa: BLE001
        log.warning("grafana annotation failed", extra={"extra": {"error": str(e)}})
        return False


# --------------------------------------------------------------- actions ----
def execute(sig, ctx):
    """Run the signature's action. Returns (ok, detail). ctx carries alert labels."""
    action = sig["action"]
    if action == "delete_pod":
        pod = ctx.get("pod")
        if not pod:
            return False, "alert carries no pod label"
        is_cl, why = _pod_crashlooping(pod)
        if not is_cl:
            return False, f"refused: {pod} is not in CrashLoopBackOff ({why}) — the alert may be stale"
        ok, out = _run(["delete", "pod", pod, "--wait=false"], timeout=30)
        return ok, f"deleted {pod} ({why}). {out}"
    if action == "rerun_settlement":
        job = f"settlement-remediator-{int(_now())}"
        ok, out = _run(["create", "job", job, "--from=cronjob/settlement"], timeout=30)
        if not ok:
            return False, f"could not create job: {out}"
        ok, detail = _job_outcome(job)
        return ok, f"created job {job} ({out[:160]}); {detail}"
    if action == "rollback_activation":
        ok, out = _run(["rollout", "undo", "deployment/activation"], timeout=60)
        if not ok:
            return False, f"rollout undo failed: {out}"
        ok2, out2 = _run(["rollout", "status", "deployment/activation", "--timeout=180s"], timeout=200)
        cause = f"REMEDIATOR rollback (approved by {ctx.get('by', 'human')}): {sig['rationale'][:80]}"
        _run(["annotate", "deployment/activation", f"kubernetes.io/change-cause={cause}", "--overwrite"], timeout=20)
        _grafana_annotate("rollback", "activation", f"REMEDIATOR rollback approved by {ctx.get('by', 'human')} (token {ctx.get('token', '?')})")
        return ok2, f"{out}. {out2}"[-400:]
    return False, f"unknown action {action}"


def _verify_after(sig, ctx):
    """Tier-1 follow-up: did the fix stick? For a deleted pod, look again after a while."""
    if sig["action"] != "delete_pod" or DRY_RUN:
        return None
    time.sleep(90)
    app_label = ctx.get("service") or ""
    ok, out = _run(["get", "pods", "-l", f"app={app_label}", "-o", "json"], timeout=20, keep=None) if app_label else (False, "")
    if not ok:
        return None
    try:
        for p in json.loads(out).get("items", []):
            for cs in p.get("status", {}).get("containerStatuses", []):
                why = _crashlooping_status(cs)
                if why:
                    return f"restart did NOT stick: {p['metadata']['name']} is crash-looping again ({why}). This is real — a human is needed."
        return "restart stuck: no pod of this service is crash-looping 90 s later"
    except Exception:  # noqa: BLE001
        return None


# --------------------------------------------------------------- handling ---
def _labels(payload):
    """service and the first alert's labels — the pod label matters for crash-loops."""
    gl = payload.get("groupLabels", {}) or {}
    alerts = payload.get("alerts", []) or []
    names = {a.get("labels", {}).get("alertname") for a in alerts}
    service = gl.get("service") or next((a["labels"].get("service") for a in alerts if a.get("labels", {}).get("service")), None)
    return names, service, alerts


def _matches(sig, names, service, alerts):
    d = sig["detect"]
    if d["alert"] not in names:
        return None
    if d.get("service") and service != d["service"]:
        return None
    ctx = {"service": service, "alert": d["alert"]}
    for a in alerts:
        if a.get("labels", {}).get("alertname") == d["alert"]:
            ctx["pod"] = a["labels"].get("pod")
            ctx["starts_at"] = a.get("startsAt")
            break
    if "deploy_within_min" in d:
        age = _recent_deploy_minutes(service, d["deploy_within_min"])
        if age is None:
            return None
        ctx["deploy_minutes_ago"] = age
    return ctx


def _handle_firing(payload):
    names, service, alerts = _labels(payload)
    if not service:
        return
    iid = _incident_for(service)
    matched = False
    for sig in SIGNATURES:
        ctx = _matches(sig, names, service, alerts)
        if ctx is None:
            continue
        matched = True
        ctx["incident"] = iid
        last = LAST_ACTION.get(sig["id"], 0)
        if _now() - last < sig.get("cooldown_s", 600):
            ACTIONS.labels(sig["id"], "auto" if sig["tier"] == 1 else "proposed", "skipped").inc()
            _record({"signature": sig["id"], "mode": "cooldown", "result": "skipped", "incident": iid})
            _note(iid, f"COOLDOWN {sig['id']}: acted {int(_now() - last)}s ago; not acting again within {sig.get('cooldown_s', 600)}s. If the alert is still firing after that, it is real.")
            continue
        if sig["tier"] == 1:
            _tier1(sig, ctx)
        else:
            _tier2_propose(sig, ctx)
    if not matched and iid and iid not in NOTED_T3:
        NOTED_T3.add(iid)
        ACTIONS.labels("none", "tier3", "human").inc()
        _record({"signature": None, "mode": "tier3", "result": "human", "incident": iid, "alerts": sorted(n for n in names if n)})
        _note(iid, f"no remediation signature matched ({', '.join(sorted(n for n in names if n))}) — tier 3: human required. "
                   f"Context and hypothesis are on this record; the fix is not an action this platform can take on its own.")


def _tier1(sig, ctx, attempt=1):
    iid = ctx.get("incident")
    LAST_ACTION[sig["id"]] = _now()
    ok, detail = execute(sig, ctx)
    ACTIONS.labels(sig["id"], "auto", "ok" if ok else "fail").inc()
    _record({"signature": sig["id"], "mode": "auto", "result": "ok" if ok else "fail", "incident": iid, "attempt": attempt, "detail": detail[:300]})
    tag = "AUTO" if attempt == 1 else f"AUTO (retry {attempt - 1}/{sig.get('retry', 0)})"
    _note(iid, f"{tag} {sig['id']} → {sig['action']}: {'succeeded' if ok else 'FAILED'}. {detail[:300]}")
    if ok:
        follow = _verify_after(sig, ctx)
        if follow:
            _note(iid, f"{sig['id']} follow-up: {follow}")
        return
    if attempt <= sig.get("retry", 0):
        delay = sig.get("retry_after_s", 180)
        _note(iid, f"{sig['id']}: will retry once in {delay}s if this incident is still open (bounded retry — a second failure is a human's problem).")
        time.sleep(delay)
        try:
            still_open = any(i.get("id") == iid for i in _bot("GET", "/incidents?status=open") or [])
        except Exception:  # noqa: BLE001
            still_open = True
        if still_open:
            _tier1(sig, ctx, attempt + 1)
        else:
            _note(iid, f"{sig['id']}: incident closed before the retry — not retrying.")


def _tier2_propose(sig, ctx):
    iid = ctx.get("incident")
    key = (sig["id"], iid)
    with _lock:
        if key in PROPOSED or any(p["signature"] == sig["id"] and p["incident"] == iid for p in PENDING.values()):
            return
        PROPOSED.add(key)
        token = f"{sig['id']}-{secrets.token_urlsafe(6)}"
        PENDING[token] = {"token": token, "signature": sig["id"], "action": sig["action"], "incident": iid,
                          "service": ctx.get("service"), "created_at": _now(), "created_at_iso": _iso(),
                          "expires_at_iso": _iso(_now() + TOKEN_TTL_S), "rationale": sig["rationale"],
                          "evidence": {k: v for k, v in ctx.items() if k in ("deploy_minutes_ago", "alert", "starts_at")},
                          "alert_started": ctx.get("starts_at")}
        PENDING_G.set(len(PENDING))
    ACTIONS.labels(sig["id"], "proposed", "pending").inc()
    _record({"signature": sig["id"], "mode": "proposed", "result": "pending", "incident": iid, "token": token})
    ev = f"deploy of {ctx.get('service')} {ctx.get('deploy_minutes_ago')} min before this alert" if "deploy_minutes_ago" in ctx else ""
    _note(iid, f"PROPOSED {sig['id']} → {sig['action']} (tier 2). Evidence: {ev}. Rationale: {sig['rationale']} "
               f"Approve: python3 tools/rem.py approve {token}   Decline: python3 tools/rem.py decline {token}   (expires {TOKEN_TTL_S // 60} min)")


def _expire_tokens():
    with _lock:
        dead = [PENDING.pop(t) for t, p in list(PENDING.items()) if _now() - p["created_at"] > TOKEN_TTL_S]
        PENDING_G.set(len(PENDING))
    for p in dead:
        ACTIONS.labels(p["signature"], "proposed", "expired").inc()
        _record({"signature": p["signature"], "mode": "proposed", "result": "expired", "incident": p["incident"], "token": p["token"]})
        _note(p["incident"], f"EXPIRED {p['signature']} — nobody approved within {TOKEN_TTL_S // 60} min (token {p['token']}).")


def _handle_resolved(payload):
    """A resolved group: drop proposals for that service (the fix is no longer needed) and
    record the recovery time next to any approved action."""
    _, service, _ = _labels(payload)
    if not service:
        return
    with _lock:
        stale = [PENDING.pop(t) for t, p in list(PENDING.items()) if p.get("service") == service]
        PENDING_G.set(len(PENDING))
        approved = next((h for h in HISTORY if h.get("mode") == "approved" and h.get("service") == service and not h.get("recovered_at_iso")), None)
    for p in stale:
        ACTIONS.labels(p["signature"], "proposed", "withdrawn").inc()
        _record({"signature": p["signature"], "mode": "proposed", "result": "withdrawn", "incident": p["incident"], "token": p["token"]})
        _note(p["incident"], f"WITHDRAWN {p['signature']} — the alerts resolved before anyone approved (token {p['token']}).")
    if approved:
        approved["recovered_at_iso"] = _iso()
        secs = round(_now() - approved.get("executed_at", _now()))
        _note(approved.get("incident"), f"RECOVERED {secs}s after the approved {approved['signature']} executed — alerts for {service} resolved.")


# --------------------------------------------------------------- endpoints --
@app.post("/alertmanager")
async def receive(request: Request):
    payload = await request.json()
    status = payload.get("status", "firing")
    WEBHOOKS.labels(status=status).inc()
    _expire_tokens()
    # Everything that touches kubectl or waits for the bot runs OFF the request path.
    target = _handle_firing if status == "firing" else _handle_resolved
    threading.Thread(target=target, args=(payload,), daemon=True, name=f"rem-{status}").start()
    return {"ok": True, "queued": status}


@app.get("/pending")
def pending():
    _expire_tokens()
    return sorted(PENDING.values(), key=lambda p: p["created_at"], reverse=True)


def _approve(token, by):
    with _lock:
        p = PENDING.pop(token, None)
        PENDING_G.set(len(PENDING))
    if not p:
        raise HTTPException(404, "unknown, expired or already-used token")
    sig = next(s for s in SIGNATURES if s["id"] == p["signature"])
    LAST_ACTION[sig["id"]] = _now()
    t0 = _now()
    _note(p["incident"], f"APPROVED {sig['id']} by {by} (token {token}) — executing {sig['action']} now.")
    ok, detail = execute(sig, {**p.get("evidence", {}), "service": p["service"], "incident": p["incident"], "by": by, "token": token})
    ACTIONS.labels(sig["id"], "approved", "ok" if ok else "fail").inc()
    entry = _record({"signature": sig["id"], "mode": "approved", "result": "ok" if ok else "fail", "incident": p["incident"],
                     "service": p["service"], "by": by, "token": token, "executed_at": _now(),
                     "execute_seconds": round(_now() - t0), "proposal_to_approval_seconds": round(t0 - p["created_at"]),
                     "detail": detail[:300]})
    _note(p["incident"], f"EXECUTED {sig['id']} → {sig['action']}: {'succeeded' if ok else 'FAILED'} in {entry['execute_seconds']}s "
                         f"({entry['proposal_to_approval_seconds']}s from proposal to approval). {detail[:300]}")
    return {"executed": ok, "signature": sig["id"], "action": sig["action"], "incident": p["incident"], "detail": detail,
            "execute_seconds": entry["execute_seconds"], "proposal_to_approval_seconds": entry["proposal_to_approval_seconds"]}


@app.post("/approve/{token}")
async def approve(token: str, request: Request):
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        body = {}
    by = (body or {}).get("by") or "human"
    # A rollback takes 30-60 s and the human wants the result: run it in a threadpool and
    # answer when done — never block the event loop, never fire-and-forget an approval.
    return await run_in_threadpool(_approve, token, by)


@app.post("/decline/{token}")
def decline(token: str):
    with _lock:
        p = PENDING.pop(token, None)
        PENDING_G.set(len(PENDING))
    if not p:
        raise HTTPException(404, "unknown, expired or already-used token")
    ACTIONS.labels(p["signature"], "proposed", "declined").inc()
    _record({"signature": p["signature"], "mode": "declined", "result": "declined", "incident": p["incident"], "token": token})
    _note(p["incident"], f"DECLINED {p['signature']} (token {token}).")
    return {"ok": True, "declined": p["signature"], "incident": p["incident"]}


@app.get("/actions")
def actions():
    return HISTORY


@app.get("/signatures")
def signatures():
    return {"signatures": SIGNATURES, "dry_run": DRY_RUN, "namespace": NS, "bot": BOT,
            "grafana_annotations": bool(GRAFANA_TOKEN), "token_ttl_s": TOKEN_TTL_S}


@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": VERSION, "dry_run": DRY_RUN}


@app.get("/readyz")
def readyz():
    return {"status": "ready", "pending": len(PENDING)}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
