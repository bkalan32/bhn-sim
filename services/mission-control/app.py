"""
mission-control — the control plane for the platform you built. Day 21.

One FastAPI app on :8040, in the cluster, one replica, a PVC for its audit log. It owns almost no
data: incidents are the bot's, proposals are the remediator's, metrics are Prometheus's, alerts
are Alertmanager's. It owns three things — the ACTION CATALOG (actions.py), the AUDIT LOG and the
tier-2 APPROVAL QUEUE (db.py) — and it serves the UI (Day 22) from `/`.

Auth (Step 4): every /api/* request needs `Authorization: Bearer <MC_TOKEN>`; every write also
needs `X-Operator: <name>` (who, for the audit row). `X-Entrance` says which door it came
through: button | command | copilot | mcp | api (default api). An empty MC_TOKEN refuses
everything — auth fails closed. /healthz, /metrics and /hooks/* are outside /api: the first two
carry nothing; /hooks/alertmanager only FEEDS the display (it can never trigger an action), and is
reachable only inside the cluster (ClusterIP, no NodePort).

Routes (Step 2)             tier   notes
  GET  /api/overview          0    one JSON, every part degrades on its own (< 2 s)
  GET  /api/events            0    SSE: hello, alert, audit, approval, health (+ 15 s heartbeat)
  GET  /api/incidents[/{id}]  0    the bot's records (?status=&since=)
  POST /api/incidents/{id}/notes 1 = action "note"
  GET  /api/approvals         0    mission control's tier-2 queue + the remediator's proposals
  POST /api/approvals/{t}/approve|decline   a human's second click (copilot/mcp refused)
  GET  /api/actions           0    the catalog
  POST /api/actions/{id}      per catalog: tier 1 runs, tier 2 queues
  GET  /api/kb, /api/kb/search?q=   0
  GET  /api/reports[/{day}]   0;  POST /api/reports/generate  1 = action "generate_report"
  GET  /api/audit             0
  GET  /api/config            0    (Day 22) what the browser needs: public Grafana/Splunk URLs, panels to embed
  GET  /api/eval, POST /api/eval   0 / 1 (Day 22) thumbs up/down on an AI draft; audited as "rate_draft"
  POST /api/chat, GET /api/kpis    501 until Days 23-24 — said, not faked
  GET  /                      the UI (Day 22): the built React app from UI_DIR, with a CSP
"""

import asyncio
import contextlib
import hmac
import json
import logging
import os
import re
import secrets
import sys
import time

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from sse_starlette.sse import EventSourceResponse

import actions
import config
from db import DB
from events import Broker, alerts_from_webhook

ENTRANCES = ("button", "command", "copilot", "mcp", "api")
HUMAN_ENTRANCES = ("button", "command", "api")   # who may APPROVE: never the AI, by construction

log = logging.getLogger("mission-control")
_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(logging.Formatter('{"ts":"%(asctime)s","level":"%(levelname)s","service":"mission-control","msg":%(message)s}'))
log.addHandler(_h); log.setLevel(logging.INFO); log.propagate = False


def jlog(msg, **kw):
    log.info(json.dumps(msg) + ("," + json.dumps(kw)[1:-1] if kw else ""))


ACTIONS = Counter("mc_actions_total", "Action attempts", ["action", "tier", "entrance", "result"])
SSE_CLIENTS = Gauge("mc_sse_clients", "Open /api/events streams")
HOOKS = Counter("mc_alertmanager_webhooks_total", "Alertmanager notifications received", ["status"])
UPSTREAM = Counter("mc_upstream_errors_total", "Upstream calls that failed", ["upstream"])
BUILD = Gauge("mc_build_info", "Build metadata", ["version"]); BUILD.labels(config.VERSION).set(1)

db = DB(f"{config.DATA_DIR}/mission-control.db")
broker = Broker()
http: httpx.AsyncClient | None = None


# ---------------------------------------------------------------- lifecycle --
class _Seen:
    """What the poller saw last time, so the feed carries only what CHANGED. None = not primed
    yet: the first pass records the present without announcing it (a restart must not replay
    every open incident into every tab as 'opened')."""
    open_incidents: dict | None = None
    rem_tokens: set | None = None
    deploy_ms: int | None = None


seen = _Seen()


async def _watch_incidents():
    try:
        cur = {i["id"]: i for i in await _open_incidents()}
    except Exception:  # noqa: BLE001 — the bot being down is a tile's problem, not the poller's
        return
    if seen.open_incidents is not None:
        for iid, i in cur.items():
            if iid not in seen.open_incidents:
                broker.publish("incident", {"event": "opened", **i})
        for iid, i in seen.open_incidents.items():
            if iid not in cur:
                try:
                    i = {k: v for k, v in (await _get("incident-bot", f"{config.BOT_URL}/incidents/{iid}")).items()
                         if k in ("id", "status", "service", "severity", "alerts", "resolved_at_iso", "duration_min")}
                except HTTPException:
                    pass
                broker.publish("incident", {"event": "resolved" if i.get("status") == "resolved" else "closed", **i})
    seen.open_incidents = cur


async def _watch_remediator():
    try:
        rem = await _get("remediator", f"{config.REM_URL}/pending")
    except HTTPException:
        return
    toks = {p.get("token"): p for p in rem if p.get("token")}
    if seen.rem_tokens is not None:
        for t, p in toks.items():
            if t not in seen.rem_tokens:
                broker.publish("approval", {"event": "proposed", "source": "remediator", "token": t,
                                            "action": p.get("action"), "params": {"service": p.get("service")},
                                            "incident": p.get("incident"), "reason": p.get("rationale")})
    seen.rem_tokens = set(toks)


async def _watch_deploys():
    """New deploy/rollback annotations since the last pass. CORRECTIONS-DAY22 B2: Grafana applies
    its time filter only when BOTH `from` and `to` are given — with `from` alone every pass got the
    whole list back and the feed showed each deploy again every 15 s. Both bounds are sent, and
    the time is also checked here, so a Grafana that ignores the filter still cannot repeat one."""
    if not config.GRAFANA_TOKEN:
        return
    now_ms = int(time.time() * 1000)
    if seen.deploy_ms is None:
        seen.deploy_ms = now_ms
        return
    try:
        r = await http.get(f"{config.GRAFANA_URL}/api/annotations",
                           params={"from": seen.deploy_ms + 1, "to": now_ms + 60_000, "limit": 50, "type": "annotation"},
                           headers={"Authorization": f"Bearer {config.GRAFANA_TOKEN}"})
        r.raise_for_status()
    except Exception:  # noqa: BLE001
        UPSTREAM.labels("grafana").inc()
        return
    newest = seen.deploy_ms
    for a in sorted(r.json(), key=lambda a: a.get("time") or 0):
        t = int(a.get("time") or 0)
        if t <= seen.deploy_ms:
            continue
        tags = a.get("tags") or []
        if "deploy" in tags or "rollback" in tags:
            broker.publish("deploy", {"kind": "rollback" if "rollback" in tags else "deploy", "time_ms": t,
                                      "service": next((x for x in tags if x not in ("deploy", "rollback")), None),
                                      "text": a.get("text")})
        newest = max(newest, t)
    seen.deploy_ms = newest


async def _health_poller():
    while True:
        try:
            await asyncio.gather(_watch_incidents(), _watch_remediator(), _watch_deploys())
        except Exception as e:  # noqa: BLE001
            jlog("watch failed", error=str(e))
        try:
            scores = await _health_scores()
            broker.publish("health", scores)
            for a in await db.expire_approvals():
                await _audit(operator="system", action=a["action"], params=a["params"], tier=a["tier"],
                             entrance="system", result="expired", token=a["token"], detail="nobody approved within 30 min")
                broker.publish("approval", {"event": "expired", **a})
        except Exception as e:  # noqa: BLE001 — the poller must survive anything
            jlog("health poll failed", error=str(e))
        await asyncio.sleep(config.HEALTH_POLL_S)


@contextlib.asynccontextmanager
async def lifespan(app):
    global http
    http = httpx.AsyncClient(timeout=config.UPSTREAM_TIMEOUT_S)
    await db.open()
    task = asyncio.create_task(_health_poller())
    jlog("started", version=config.VERSION, dry_run=config.DRY_RUN, auth="on" if config.MC_TOKEN else "REFUSING (no MC_TOKEN)")
    yield
    task.cancel()
    await http.aclose()
    await db.close()


app = FastAPI(title="mission-control", version=config.VERSION, lifespan=lifespan)


# --------------------------------------------------------------------- auth --
class Caller:
    def __init__(self, operator, entrance):
        self.operator, self.entrance = operator, entrance


def _token_ok(presented: str) -> bool:
    return bool(config.MC_TOKEN) and hmac.compare_digest(presented.encode(), config.MC_TOKEN.encode())


async def caller(request: Request, authorization: str = Header(""), x_operator: str = Header(""),
                 x_entrance: str = Header("api")) -> Caller:
    presented = authorization[7:] if authorization.startswith("Bearer ") else ""
    # EventSource cannot send headers: GET /api/events alone may carry ?access_token= (never logged:
    # uvicorn runs with --no-access-log).
    if not presented and request.url.path == "/api/events":
        presented = request.query_params.get("access_token", "")
    if not _token_ok(presented):
        raise HTTPException(401, "missing or wrong bearer token", headers={"WWW-Authenticate": "Bearer"})
    entrance = (x_entrance or "api").lower()
    if entrance not in ENTRANCES:
        raise HTTPException(400, f"X-Entrance: one of {', '.join(ENTRANCES)}")
    op = (x_operator or "").strip()
    if op and not re.fullmatch(r"[A-Za-z0-9_.@ -]{1,60}", op):
        raise HTTPException(400, "X-Operator: letters, digits, . _ @ - and spaces, up to 60")
    return Caller(op, entrance)


def writer(c: Caller = Depends(caller)) -> Caller:
    if not c.operator:
        raise HTTPException(400, "X-Operator required on every write — the audit row needs a name")
    return c


# -------------------------------------------------------------------- audit --
async def _audit(**kw) -> dict:
    row = await db.audit(**kw)
    ACTIONS.labels(kw["action"], str(kw["tier"]), kw["entrance"], kw["result"]).inc()
    broker.publish("audit", row)
    jlog("audit", **{k: v for k, v in row.items() if k != "detail"})
    return row


async def run_action(action_id: str, raw_params: dict, reason: str, c: Caller) -> dict:
    """THE path every entrance takes. Validate -> tier 1: execute + audit; tier 2: queue + audit."""
    a = actions.CATALOG.get(action_id)
    if not a:
        raise HTTPException(404, f"no action '{action_id}' in the catalog (tier 3 has no actions: escalate)")
    try:
        params = actions.validate(action_id, raw_params)
    except actions.ParamError as e:
        await _audit(operator=c.operator, action=action_id, params=raw_params or {}, tier=a["tier"],
                     entrance=c.entrance, result="rejected", detail=str(e))
        raise HTTPException(422, str(e))
    if a["tier"] == 2:
        token = f"{action_id}-{secrets.token_urlsafe(8)}"
        ap = await db.add_approval(token=token, action=action_id, params=params, reason=reason or "",
                                   tier=2, entrance=c.entrance, operator=c.operator)
        await _audit(operator=c.operator, action=action_id, params=params, tier=2, entrance=c.entrance,
                     result="pending", token=token, detail=reason or "")
        broker.publish("approval", {"event": "created", **ap, "blast_radius": a["blast_radius"], "rationale": a["rationale"]})
        return {"status": "pending_approval", "token": token, "action": action_id, "params": params,
                "blast_radius": a["blast_radius"], "rationale": a["rationale"], "expires_at_iso": ap["expires_at_iso"]}
    return await _execute(action_id, params, c.operator, c.entrance, token=None)


async def _execute(action_id, params, operator, entrance, token):
    a = actions.CATALOG[action_id]
    t0 = time.perf_counter()
    try:
        ok, detail = await a["execute"](http, params, operator)
    except Exception as e:  # noqa: BLE001
        ok, detail = False, f"{type(e).__name__}: {e}"
    row = await _audit(operator=operator, action=action_id, params=params, tier=a["tier"], entrance=entrance,
                       result="ok" if ok else "failed", token=token, detail=detail)
    return {"status": "executed" if ok else "failed", "action": action_id, "params": params, "detail": detail,
            "audit_id": row["id"], "seconds": round(time.perf_counter() - t0, 2)}


# ---------------------------------------------------------------- upstreams --
async def _get(name, url, **params):
    try:
        r = await http.get(url, params=params or None)
        r.raise_for_status()
        return r.json()
    except Exception as e:  # noqa: BLE001
        UPSTREAM.labels(name).inc()
        raise HTTPException(502, f"{name}: {type(e).__name__}: {str(e)[:200]}")


async def _prom(query):
    d = await _get("prometheus", f"{config.PROM_URL}/api/v1/query", query=query)
    return d.get("data", {}).get("result", [])


async def _health_scores() -> dict:
    res = await _prom('{__name__=~"(activation|egift|settlement|platform):health_score"}')
    return {r["metric"]["__name__"].split(":")[0]: round(float(r["value"][1]), 1) for r in res}


async def _part(name, coro):
    """One piece of the overview. A dead upstream is a message on that tile, not a 500 for the page."""
    t0 = time.perf_counter()
    try:
        data = await coro
        return {"ok": True, "ms": round((time.perf_counter() - t0) * 1000), "data": data}
    except HTTPException as e:
        return {"ok": False, "error": e.detail}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


async def _sparklines():
    end = time.time()
    d = await _get("prometheus", f"{config.PROM_URL}/api/v1/query_range",
                   query='{__name__=~"(activation|egift|settlement|platform):health_score"}',
                   start=end - 3600, end=end, step=60)   # 1 h, one point a minute (Day 22)
    return {r["metric"]["__name__"].split(":")[0]: [round(float(v), 1) for _, v in r["values"]]
            for r in d.get("data", {}).get("result", [])}


async def _alerts():
    d = await _get("alertmanager", f"{config.AM_URL}/api/v2/alerts", active="true", silenced="false", inhibited="false")
    keep = [a for a in d if a.get("labels", {}).get("alertname") not in ("Watchdog", "InfoInhibitor")
            and a.get("labels", {}).get("severity") in ("critical", "warning")]
    return [{"alertname": a["labels"].get("alertname"), "service": a["labels"].get("service"),
             "severity": a["labels"].get("severity"), "startsAt": a.get("startsAt"),
             "summary": a.get("annotations", {}).get("summary")} for a in keep]


async def _deploys_today():
    if not config.GRAFANA_TOKEN:
        raise HTTPException(503, "no Grafana token (secret/enrich-config GRAFANA_TOKEN)")
    import datetime as _dt
    midnight = _dt.datetime.now(_dt.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    try:
        r = await http.get(f"{config.GRAFANA_URL}/api/annotations",
                           params={"tags": "deploy", "from": int(midnight * 1000), "to": int(time.time() * 1000) + 60_000, "limit": 100},   # both bounds: B2
                           headers={"Authorization": f"Bearer {config.GRAFANA_TOKEN}"})
        r.raise_for_status()
    except Exception as e:  # noqa: BLE001
        UPSTREAM.labels("grafana").inc()
        raise HTTPException(502, f"grafana: {e}")
    return [{"time_ms": a.get("time"), "text": a.get("text"), "tags": a.get("tags")} for a in r.json()]


async def _traffic():
    res = await _prom('sum by (target) (rate(loadgen_requests_total[2m]))')
    mult = await _prom('loadgen_rate_multiplier')
    return {"rps": {r["metric"].get("target"): round(float(r["value"][1]), 2) for r in res},
            "multiplier": {r["metric"].get("target"): float(r["value"][1]) for r in mult}}


async def _settlement_age():
    res = await _prom("time() - max(settlement_last_success_timestamp)")
    return round(float(res[0]["value"][1])) if res else None


async def _open_incidents():
    return await _get("incident-bot", f"{config.BOT_URL}/incidents", status="open")


async def _all_approvals():
    mine = await db.approvals()
    try:
        rem = await _get("remediator", f"{config.REM_URL}/pending")
    except HTTPException:
        rem = []
    theirs = [{"token": p.get("token"), "action": p.get("action"), "signature": p.get("signature"),
               "params": {"service": p.get("service")}, "reason": p.get("rationale"), "tier": 2,
               "entrance": "remediator", "operator": "remediator", "incident": p.get("incident"),
               "created_at_iso": p.get("created_at_iso"), "expires_at_iso": p.get("expires_at_iso"),
               "source": "remediator"} for p in rem]
    return mine + theirs


# ------------------------------------------------------------------- routes --
@app.get("/api/overview")
async def overview(c: Caller = Depends(caller)):
    t0 = time.perf_counter()
    names = ("health", "sparklines", "alerts", "incidents", "approvals", "deploys_today", "settlement_age_s", "traffic")
    parts = await asyncio.gather(_part("health", _health_scores()), _part("sparklines", _sparklines()),
                                 _part("alerts", _alerts()), _part("incidents", _open_incidents()),
                                 _part("approvals", _all_approvals()), _part("deploys", _deploys_today()),
                                 _part("settlement", _settlement_age()), _part("traffic", _traffic()))
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ms": round((time.perf_counter() - t0) * 1000), **dict(zip(names, parts))}


@app.get("/api/events")
async def events(request: Request, c: Caller = Depends(caller)):
    q = broker.subscribe()
    SSE_CLIENTS.inc()

    async def stream():
        try:
            yield {"event": "hello", "data": json.dumps({"server_time": time.time(), "kinds": ["alert", "audit", "approval", "health", "incident", "deploy"]})}
            while True:
                if await request.is_disconnected():
                    break
                try:
                    ev = await asyncio.wait_for(q.get(), timeout=5)
                except asyncio.TimeoutError:
                    continue
                yield {"event": ev["kind"], "id": str(ev["id"]), "data": json.dumps(ev["data"], default=str)}
        finally:
            broker.unsubscribe(q)
            SSE_CLIENTS.dec()
    return EventSourceResponse(stream(), ping=15)


@app.get("/api/incidents")
async def incidents(status: str | None = None, since: str | None = None, c: Caller = Depends(caller)):
    params = {k: v for k, v in (("status", status), ("since", since)) if v}
    return await _get("incident-bot", f"{config.BOT_URL}/incidents", **params)


@app.get("/api/incidents/{iid}")
async def incident(iid: str, c: Caller = Depends(caller)):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", iid):
        raise HTTPException(400, "bad incident id")
    return await _get("incident-bot", f"{config.BOT_URL}/incidents/{iid}")


@app.post("/api/incidents/{iid}/notes")
async def add_note(iid: str, request: Request, c: Caller = Depends(writer)):
    body = await request.json()
    return await run_action("note", {"incident": iid, "text": (body or {}).get("text")}, "", c)


@app.get("/api/actions")
async def list_actions(c: Caller = Depends(caller)):
    return {"tiers": {"1": "auto: one click, audited", "2": "approve: a second click by a human, audited",
                      "3": "human: no action exists — escalate"}, "actions": actions.public_catalog()}


@app.post("/api/actions/{action_id}")
async def post_action(action_id: str, request: Request, c: Caller = Depends(writer)):
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        body = {}
    return await run_action(action_id, (body or {}).get("params") or {}, (body or {}).get("reason") or "", c)


@app.get("/api/approvals")
async def approvals(c: Caller = Depends(caller)):
    return await _all_approvals()


async def _decide(token: str, approve: bool, c: Caller):
    if c.entrance not in HUMAN_ENTRANCES:
        await _audit(operator=c.operator, action="approval", params={"token": token}, tier=2, entrance=c.entrance,
                     result="refused", token=token, detail="approvals are human: copilot and mcp may propose, never approve")
        raise HTTPException(403, "approvals are human — the copilot and MCP may propose, never approve")
    ap = await db.take_approval(token)                      # single-use: one DELETE … RETURNING
    if ap:
        broker.publish("approval", {"event": "approved" if approve else "declined", "by": c.operator, **ap})
        if not approve:
            await _audit(operator=c.operator, action=ap["action"], params=ap["params"], tier=2, entrance=c.entrance,
                         result="declined", token=token, detail=f"requested by {ap['operator']} via {ap['entrance']}")
            return {"status": "declined", "token": token, "action": ap["action"]}
        res = await _execute(ap["action"], ap["params"], c.operator, c.entrance, token=token)
        return {**res, "approved_by": c.operator, "requested_by": ap["operator"], "requested_via": ap["entrance"]}
    # Not ours: a remediator proposal? It has its own single-use token store (Day 21 chore 2).
    path = "approve" if approve else "decline"
    try:
        r = await http.post(f"{config.REM_URL}/{path}/{token}", json={"by": c.operator}, timeout=120)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"remediator: {e}")
    if r.status_code == 404:
        raise HTTPException(404, "unknown, expired or already-used token")
    detail = r.text[:500]
    await _audit(operator=c.operator, action=f"remediator:{path}", params={"token": token}, tier=2, entrance=c.entrance,
                 result="ok" if r.status_code == 200 else "failed", token=token, detail=detail)
    broker.publish("approval", {"event": f"remediator-{path}d", "token": token, "by": c.operator})
    return {"status": f"remediator {path}d" if r.status_code == 200 else "failed", "token": token, "detail": r.json() if r.status_code == 200 else detail}


@app.post("/api/approvals/{token}/approve")
async def approve(token: str, c: Caller = Depends(writer)):
    return await _decide(token, True, c)


@app.post("/api/approvals/{token}/decline")
async def decline(token: str, c: Caller = Depends(writer)):
    return await _decide(token, False, c)


@app.get("/api/kb")
async def kb(c: Caller = Depends(caller)):
    ok, out = await actions.kubectl("get", "configmap", "kb", "-o", "json", keep=None)
    if not ok:
        raise HTTPException(502, f"kb: {out[:200]}")
    if config.DRY_RUN:
        return []
    files = json.loads(out).get("data", {})
    entries = []
    for name, text in sorted(files.items()):
        if name == "README.md":
            continue
        fm = dict(re.findall(r"^(\w+):\s*(.+)$", text.split("---")[1], re.M)) if text.startswith("---") else {}
        entries.append({"file": name, "id": fm.get("id"), "title": fm.get("title"), "tier": fm.get("tier"),
                        "fix": fm.get("fix"), "services": [x.strip() for x in fm.get("services", "").strip("[]").split(",") if x.strip()],
                        "markdown": text})
    return entries


@app.get("/api/kb/search")
async def kb_search(q: str, c: Caller = Depends(caller)):
    return await _get("incident-bot", f"{config.BOT_URL}/kb/search", q=q)


@app.get("/api/reports")
async def reports(c: Caller = Depends(caller)):
    return await _get("incident-bot", f"{config.BOT_URL}/reports")


@app.get("/api/reports/{day}")
async def report(day: str, c: Caller = Depends(caller)):
    if not re.fullmatch(r"[0-9A-Za-z_-]{1,40}", day):
        raise HTTPException(400, "bad day")
    return await _get("incident-bot", f"{config.BOT_URL}/reports/{day}")


@app.post("/api/reports/generate")
async def generate(c: Caller = Depends(writer)):
    return await run_action("generate_report", {}, "", c)


@app.get("/api/audit")
async def audit(limit: int = 100, action: str | None = None, c: Caller = Depends(caller)):
    return await db.audit_rows(limit=min(max(limit, 1), 1000), action=action)


DRAFTS = ("open", "hypothesis", "resolved")


@app.get("/api/eval")
async def evals(incident: str | None = None, c: Caller = Depends(caller)):
    return await db.evals(incident=incident)


@app.post("/api/eval")
async def rate_draft(request: Request, c: Caller = Depends(writer)):
    """A thumbs up/down on an AI draft (Day 22's incident page). Tier 1: it writes MC's own table,
    not the platform, so it is not a catalog action — but it is audited like one."""
    body = await request.json()
    incident, draft, verdict = (body or {}).get("incident", ""), (body or {}).get("draft"), (body or {}).get("verdict")
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", incident or ""):
        raise HTTPException(422, "incident: an incident id")
    if draft not in DRAFTS:
        raise HTTPException(422, f"draft: one of {', '.join(DRAFTS)}")
    if verdict not in ("up", "down"):
        raise HTTPException(422, "verdict: up or down")
    row = await db.add_eval(operator=c.operator, incident=incident, draft=draft, verdict=verdict,
                            comment=str((body or {}).get("comment") or ""), model=(body or {}).get("model"))
    await _audit(operator=c.operator, action="rate_draft", params={"incident": incident, "draft": draft, "verdict": verdict},
                 tier=1, entrance=c.entrance, result="ok", detail=row["comment"])
    return row


@app.get("/api/config")
async def ui_config(c: Caller = Depends(caller)):
    """Everything the browser needs to build links and iframes. Public addresses only — no secrets."""
    return {"version": config.VERSION, "grafana_url": config.GRAFANA_PUBLIC_URL, "splunk_url": config.SPLUNK_PUBLIC_URL,
            "prom_datasource_uid": config.PROM_DATASOURCE_UID, "embed_panels": config.EMBED_PANELS,
            "metric_queries": config.METRIC_QUERIES, "log_reasons_spl": config.LOG_REASONS_SPL,
            "dry_run": config.DRY_RUN}


@app.api_route("/api/chat", methods=["POST"])
@app.api_route("/api/kpis", methods=["GET"])
async def later(request: Request, c: Caller = Depends(caller)):
    day = {"/api/chat": 23, "/api/kpis": 24}[request.url.path]
    return JSONResponse({"detail": f"not built yet — Day {day}"}, status_code=501)


# ---------------------------------------------------------------- the feed --
@app.post("/hooks/alertmanager")
async def am_hook(request: Request):
    """Alertmanager's third webhook (k8s/kps-values.yaml). Display only: nothing here can act."""
    payload = await request.json()
    HOOKS.labels(payload.get("status", "?")).inc()
    for a in alerts_from_webhook(payload):
        broker.publish("alert", a)
    return {"ok": True}


# ------------------------------------------------------------------ health --
@app.get("/healthz")
async def healthz():
    return {"status": "ok", "version": config.VERSION}


@app.get("/readyz")
async def readyz():
    try:
        await db.conn.execute("SELECT 1")
    except Exception as e:  # noqa: BLE001
        raise HTTPException(503, f"db: {e}")
    return {"status": "ready", "auth": bool(config.MC_TOKEN), "dry_run": config.DRY_RUN, "sse_clients": len(broker.subscribers)}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# ---------------------------------------------------------------------- UI --
# The page itself is public (it is a login form until you give it the token); every byte of
# DATA behind it is under /api/ and needs the bearer token. The CSP says what the page may load:
# its own scripts, iframes from Grafana only, fetch/SSE to itself only.
def _csp() -> str:
    return ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
            f"connect-src 'self'; frame-src {config.GRAFANA_PUBLIC_URL}; frame-ancestors 'none'; base-uri 'none'; "
            "form-action 'self'")


def _ui_ready() -> bool:
    return os.path.isfile(os.path.join(config.UI_DIR, "index.html"))


if _ui_ready() and os.path.isdir(os.path.join(config.UI_DIR, "assets")):
    app.mount("/assets", StaticFiles(directory=os.path.join(config.UI_DIR, "assets")), name="assets")


@app.get("/")
async def root():
    if not _ui_ready():
        return {"service": "mission-control", "version": config.VERSION, "ui": "not built into this image",
                "api": "/docs (bearer token required for /api/*)"}
    return FileResponse(os.path.join(config.UI_DIR, "index.html"), headers={
        "Content-Security-Policy": _csp(), "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer"})
