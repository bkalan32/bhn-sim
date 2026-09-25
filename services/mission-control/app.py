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
  POST /api/chat              0*   (Day 23) the copilot, streamed as SSE; *its only write is propose_action,
                                    which queues a tier-2 approval (entrance copilot) — never executes
  GET  /api/chat/turns        0    every copilot answer, for the eval page
  /mcp                             (Day 23) the same tools as an MCP server, same token, entrance mcp
  GET  /api/kpis              501 until Day 24 — said, not faked
  GET  /                      the UI (Day 22): the built React app from UI_DIR, with a CSP
"""

import asyncio
import contextvars
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
import yaml
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest
from sse_starlette.sse import EventSourceResponse

import actions
import config
import copilot
import gameday
import kbparse
import kpis as kpi
import mcp_server
from db import DB
from events import Broker, alerts_from_webhook, KINDS

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
COPILOT = Counter("mc_copilot_answers_total", "Copilot questions answered", ["outcome"])

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
    report_since: float | None = None      # Day 24: waiting for a report "Generate now" asked for
    report_until: float = 0.0


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


async def _watch_reports():
    """After Generate now: the Jenkins job takes a minute or three, then POSTs to the bot. Poll the
    bot's list until a report stored after the click appears, then tell every tab ("streams the
    result in when the bot receives it"). Nobody asked → nothing is polled."""
    if seen.report_since is None:
        return
    if time.time() > seen.report_until:
        broker.publish("report", {"event": "timeout", "note": "no report arrived within 15 min — check the daily-ops-report job"})
        seen.report_since = None
        return
    try:
        reps = await _get("incident-bot", f"{config.BOT_URL}/reports")
    except HTTPException:
        return
    since = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(seen.report_since - 5))
    new = [r for r in reps if (r.get("stored_at_iso") or "") >= since]
    if new:
        broker.publish("report", {"event": "arrived", **new[0]})
        seen.report_since = None


async def _health_poller():
    while True:
        try:
            await asyncio.gather(_watch_incidents(), _watch_remediator(), _watch_deploys(), _watch_reports())
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
    global hands
    hands = AuditedHands(http, propose, proposal_status)
    await db.open()
    await db.prune_feed(days=30)
    global _loop
    _loop = asyncio.get_running_loop()
    broker.on_publish = _keep                       # Day 24: the feed is kept for run timelines
    global runner
    runner = gameday.Runner(db, lambda: http, _audit, broker.publish)
    actions.HOOKS.update(scenarios=lambda: [k for k in gameday.load_scenarios() if not k.startswith("_")],
                         start_run=_start_run, abort_runs=lambda op, why: runner.abort(op, why))
    await runner.resume()                           # a run interrupted by a restart keeps going
    await db.setting("kb_feeding_since", str(time.time()), store_default=True)
    task = asyncio.create_task(_health_poller())
    jlog("started", version=config.VERSION, dry_run=config.DRY_RUN, auth="on" if config.MC_TOKEN else "REFUSING (no MC_TOKEN)",
         copilot=config.COPILOT_MODEL if config.ANTHROPIC_API_KEY else "off (no key)")
    global mcp, _mcp_asgi                             # a session manager runs once: a fresh one per start
    mcp, _mcp_asgi = mcp_server.build(lambda: hands)
    async with mcp.session_manager.run():            # the MCP app's task group lives as long as ours
        yield
    task.cancel()
    await http.aclose()
    await db.close()


runner: gameday.Runner | None = None
_TOKEN = contextvars.ContextVar("approval_token", default=None)   # the token an executing action was approved with


_loop: asyncio.AbstractEventLoop | None = None       # the app's loop, set in lifespan


def _keep(ev: dict):
    """Persist a feed event — always on the APP's loop. A write started on some other loop (a test's
    asyncio.run, a thread) would be cancelled when that loop closes, mid-statement, and the one
    aiosqlite connection would wait for ever on the reply (found by the test suite hanging)."""
    if _loop is None or _loop.is_closed():
        return
    _loop.call_soon_threadsafe(lambda: _loop.create_task(db.add_feed(ev["ts"], ev["kind"], ev["data"])))


async def _start_run(scenario: str, operator: str):
    return await runner.start(scenario, operator, token=_TOKEN.get())


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
    tok = _TOKEN.set(token)
    try:
        ok, detail = await a["execute"](http, params, operator)
    except Exception as e:  # noqa: BLE001
        ok, detail = False, f"{type(e).__name__}: {e}"
    finally:
        _TOKEN.reset(tok)
    if action_id == "generate_report" and ok:
        seen.report_since, seen.report_until = time.time(), time.time() + 900
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
    names = ("health", "sparklines", "alerts", "incidents", "approvals", "deploys_today", "settlement_age_s", "traffic", "needs_human")
    parts = await asyncio.gather(_part("health", _health_scores()), _part("sparklines", _sparklines()),
                                 _part("alerts", _alerts()), _part("incidents", _open_incidents()),
                                 _part("approvals", _all_approvals()), _part("deploys", _deploys_today()),
                                 _part("settlement", _settlement_age()), _part("traffic", _traffic()),
                                 _part("needs_human", _needs_human()))
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ms": round((time.perf_counter() - t0) * 1000), **dict(zip(names, parts))}


@app.get("/api/events")
async def events(request: Request, c: Caller = Depends(caller)):
    q = broker.subscribe()
    SSE_CLIENTS.inc()

    async def stream():
        try:
            yield {"event": "hello", "data": json.dumps({"server_time": time.time(), "kinds": [k for k in KINDS if k != "hello"]})}
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


@app.get("/api/feed")
async def feed(limit: int = 40, c: Caller = Depends(caller)):
    """Day 24: the kept feed, newest first — a fresh tab (or a reload mid-game-day) starts with what
    already happened, not an empty column. Tool reads are left out: they are the copilot's, not the feed's."""
    async with db.conn.execute("SELECT id, ts, kind, data FROM feed ORDER BY id DESC LIMIT ?", (min(max(limit, 1), 200) * 2,)) as cur:
        rows = [{"id": r["id"], "ts": r["ts"], "kind": r["kind"], "data": json.loads(r["data"])} for r in await cur.fetchall()]
    rows = [r for r in rows if not (r["kind"] == "audit" and str(r["data"].get("action", "")).startswith("tool:"))]
    return rows[:limit]


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
    # Day 24: the front matter parsed properly (YAML), so the cards can show symptoms, checks and
    # learned_from as lists — the Day 22 line regex could only see one-line keys.
    return [_kb_entry(name, text) for name, text in sorted(files.items()) if name != "README.md"]


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
async def rate(request: Request, c: Caller = Depends(writer)):
    """A thumbs up/down — on an AI draft (Day 22's incident page: {incident, draft, verdict}) or on a
    copilot answer (Day 23: {turn_id, verdict}). Tier 1: it writes MC's own table, not the platform,
    so it is not a catalog action — but it is audited like one."""
    body = await request.json() or {}
    verdict, comment = body.get("verdict"), str(body.get("comment") or "")
    if verdict not in ("up", "down"):
        raise HTTPException(422, "verdict: up or down")
    if body.get("turn_id") is not None:
        try:
            turn = await db.turn(int(body["turn_id"]))
        except (TypeError, ValueError):
            turn = None
        if not turn:
            raise HTTPException(404, "no such copilot answer")
        row = await db.add_eval(operator=c.operator, incident=turn["incident"] or "-", draft="copilot", verdict=verdict,
                                comment=comment, model=turn["model"], turn_id=turn["id"])
        await _audit(operator=c.operator, action="rate_answer", params={"turn_id": turn["id"], "verdict": verdict},
                     tier=1, entrance=c.entrance, result="ok", detail=row["comment"])
        return row
    if body.get("report"):                     # Day 24: a daily report, graded like a copilot answer
        day = str(body["report"])
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}(-[a-z0-9-]{1,24})?", day):
            raise HTTPException(422, "report: YYYY-MM-DD[-slug]")
        row = await db.add_eval(operator=c.operator, incident=f"report:{day}", draft="report", verdict=verdict,
                                comment=comment, model=body.get("model"))
        await _audit(operator=c.operator, action="rate_report", params={"report": day, "verdict": verdict},
                     tier=1, entrance=c.entrance, result="ok", detail=row["comment"])
        return row
    incident, draft = body.get("incident", ""), body.get("draft")
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", incident or ""):
        raise HTTPException(422, "incident: an incident id")
    if draft not in DRAFTS:
        raise HTTPException(422, f"draft: one of {', '.join(DRAFTS)}")
    row = await db.add_eval(operator=c.operator, incident=incident, draft=draft, verdict=verdict,
                            comment=comment, model=body.get("model"))
    await _audit(operator=c.operator, action="rate_draft", params={"incident": incident, "draft": draft, "verdict": verdict},
                 tier=1, entrance=c.entrance, result="ok", detail=row["comment"])
    return row


@app.get("/api/config")
async def ui_config(c: Caller = Depends(caller)):
    """Everything the browser needs to build links and iframes. Public addresses only — no secrets."""
    return {"version": config.VERSION, "grafana_url": config.GRAFANA_PUBLIC_URL, "splunk_url": config.SPLUNK_PUBLIC_URL,
            "prom_datasource_uid": config.PROM_DATASOURCE_UID, "embed_panels": config.EMBED_PANELS,
            "metric_queries": config.METRIC_QUERIES, "log_reasons_spl": config.LOG_REASONS_SPL,
            "copilot": {"enabled": bool(config.ANTHROPIC_API_KEY), "model": config.COPILOT_MODEL,
                        "tool_budget": copilot.TOOL_CALL_BUDGET, "features": copilot.FEATURES},
            "repo_url": config.REPO_URL, "annotations": bool(config.GRAFANA_WRITE_TOKEN),
            "dry_run": config.DRY_RUN}


# ----------------------------------------------------------------- copilot --
# Day 23. The copilot's hands are copilot.Hands; these two additions make them Mission Control's:
# every tool call is an audit row (tier 0, entrance copilot|mcp — "what did the AI look at" is one
# query), and propose_action goes through the SAME approval queue as a button.
async def propose(action_id, params, reason, ctx) -> dict:
    """The copilot's and the MCP client's only write: a pending approval, never an execution."""
    a = actions.CATALOG.get(action_id)
    who, door = ctx["operator"], ctx["entrance"]
    if not a:
        await _audit(operator=who, action=str(action_id)[:60], params=params or {}, tier=2, entrance=door,
                     result="rejected", detail="not in the catalog")
        return {"error": f"'{action_id}' is not in the catalog: not an action anyone can take here (tier 3: escalate)"}
    clean = {k: v for k, v in (params or {}).items() if v not in (None, "")}
    extra = set(clean) - set(a["params"])
    if extra:
        return {"error": f"{action_id} takes {', '.join(a['params']) or 'no parameters'} — not {', '.join(sorted(extra))}"}
    try:
        p = actions.validate(action_id, clean)
    except actions.ParamError as e:
        await _audit(operator=who, action=action_id, params=clean, tier=2, entrance=door, result="rejected", detail=str(e))
        return {"error": str(e)}
    token = f"{action_id}-{secrets.token_urlsafe(8)}"
    ap = await db.add_approval(token=token, action=action_id, params=p, reason=(reason or "")[:500], tier=2,
                               entrance=door, operator=who)
    await _audit(operator=who, action=action_id, params=p, tier=2, entrance=door, result="pending", token=token,
                 detail=f"proposed by the {door}: {reason}"[:500])
    broker.publish("approval", {"event": "created", **ap, "blast_radius": a["blast_radius"], "rationale": a["rationale"]})
    return {"status": "pending_approval", "token": token, "action": action_id, "params": p,
            "note": "Queued for a human. It has NOT run. It runs only if a human approves it in Mission Control "
                    "(the pending-approvals banner); it expires in 30 minutes."}


_STATUS = {"pending": "pending: waiting for a human in the approvals banner", "ok": "approved and executed",
           "failed": "approved, but the execution failed", "declined": "declined by a human",
           "expired": "expired: nobody approved it within 30 minutes", "rejected": "rejected: invalid proposal"}


async def proposal_status(token: str) -> dict:
    """The copilot's read of its own proposals, from the audit log (the approval row itself is deleted when
    it is used). On 24 Sep it wrote "my note has probably expired" 5 minutes after K approved it (N8)."""
    token = token.strip()[:120]
    if token.lower() in ("pending", "*", "all", ""):
        # What is waiting in the banner right now — K's 👎 on "approve the pending rollback": the copilot
        # talked about a card it could not see (CORRECTIONS-DAY23 N12).
        waiting = await _all_approvals()
        return {"pending_cards": [{"token": a.get("token"), "action": a.get("action"), "params": a.get("params"),
                                   "requested_by": a.get("operator"), "via": a.get("entrance"),
                                   "incident": a.get("incident"), "reason": (a.get("reason") or "")[:200],
                                   "expires_at_iso": a.get("expires_at_iso")} for a in waiting],
                "note": None if waiting else "nothing is waiting for approval — the banner is empty"}
    async with db.conn.execute("SELECT ts_iso, operator, entrance, action, result, detail FROM audit "
                               "WHERE approval_token = ? ORDER BY id", (token,)) as cur:
        rows = [dict(r) for r in await cur.fetchall()]
    rows = [r for r in rows if r["result"] != "refused"]          # an AI's refused approve attempt is not a decision
    if not rows:
        return {"token": token, "status": "unknown token (not in mission control's audit log; remediator proposals "
                                          "live in the remediator)"}
    last = rows[-1]
    out = {"token": token, "action": last["action"], "status": _STATUS.get(last["result"], last["result"]),
           "requested": {"by": rows[0]["operator"], "via": rows[0]["entrance"], "at": rows[0]["ts_iso"]}}
    if last["result"] != "pending":
        out["decided"] = {"by": last["operator"], "via": last["entrance"], "at": last["ts_iso"],
                          "detail": (last["detail"] or "")[:300]}
    return out


class AuditedHands(copilot.Hands):
    async def call(self, name, args, ctx):
        out = await super().call(name, args, ctx)
        if name != "propose_action":                   # a proposal audits itself, with its token
            await _audit(operator=ctx["operator"], action=f"tool:{name}",
                         params={k: str(v)[:300] for k, v in (args or {}).items()}, tier=0, entrance=ctx["entrance"],
                         result="error" if isinstance(out, dict) and out.get("error") else "ok",
                         detail=copilot.summarize(name, out))
        return out


conversations = copilot.Conversations()
_busy: set[str] = set()
hands: AuditedHands | None = None


@app.post("/api/chat")
async def chat(request: Request, c: Caller = Depends(writer)):
    """One question; the answer streams back as SSE: conversation, thinking, tool_start, tool_call,
    text, fallback, done (with turn_id — what a thumbs up/down grades) or error."""
    if not config.ANTHROPIC_API_KEY:
        raise HTTPException(503, "copilot not configured: no ANTHROPIC_API_KEY (secret/ai-keys — scripts/90-ai-secret.sh)")
    body = await request.json() or {}
    msg = str(body.get("message") or "").strip()
    if not msg or len(msg) > 4000:
        raise HTTPException(422, "message: 1-4000 characters")
    inc = body.get("incident") or None
    if inc and not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", str(inc)):
        raise HTTPException(422, "incident: an incident id")
    conv = conversations.get_or_create(body.get("conversation_id"), c.operator, inc)
    if conv["id"] in _busy:
        raise HTTPException(409, "this conversation is still answering")
    question = msg
    if conv["incident"] and not conv["messages"]:
        question = f"[Investigating incident {conv['incident']} — start from get_incident.]\n\n{msg}"
    q: asyncio.Queue = asyncio.Queue()

    async def emit(kind, data):
        await q.put((kind, data))

    ctx = {"operator": c.operator, "entrance": "copilot"}

    async def worker():
        _busy.add(conv["id"])
        try:
            rec = await copilot.run_turn(http, conv, question, hands, emit, ctx)
            rec["question"] = msg
            turn_id = await db.add_turn(conversation=conv["id"], incident=conv["incident"], operator=c.operator,
                                        entrance="copilot", rec=rec)
            COPILOT.labels("ok" if rec["answer"] and not rec["note"] else "partial").inc()
            await emit("done", {"turn_id": turn_id, "conversation_id": conv["id"], "answer": rec["answer"],
                                "note": rec["note"], "model": rec["model"], "tokens_in": rec["tokens_in"],
                                "tokens_out": rec["tokens_out"], "cache_read": rec["cache_read"],
                                "cost_usd": rec["cost_usd"], "ms": rec["ms"], "tool_calls": len(rec["trail"])})
        except Exception as e:  # noqa: BLE001
            COPILOT.labels("error").inc()
            await emit("error", {"detail": f"{type(e).__name__}: {str(e)[:300]}"})
        finally:
            _busy.discard(conv["id"])
            await q.put(None)

    asyncio.create_task(worker())

    async def stream():
        yield {"event": "conversation", "data": json.dumps({"conversation_id": conv["id"], "incident": conv["incident"],
                                                            "model": config.COPILOT_MODEL})}
        while True:
            item = await q.get()
            if item is None:
                break
            yield {"event": item[0], "data": json.dumps(item[1], default=str)}
    return EventSourceResponse(stream(), ping=15)


@app.get("/api/chat/turns")
async def turns(limit: int = 50, c: Caller = Depends(caller)):
    async with db.conn.execute("SELECT id, ts_iso, conversation, incident, operator, entrance, question, model, "
                               "tokens_in, tokens_out, cost_usd, ms, json_array_length(trail) AS tool_calls, "
                               "(SELECT GROUP_CONCAT(json_extract(j.value, '$.name')) FROM json_each(turns.trail) j) AS tools "
                               "FROM turns ORDER BY id DESC LIMIT ?",
                               (min(max(limit, 1), 500),)) as cur:
        return [dict(r) for r in await cur.fetchall()]


# ----------------------------------------------------------------- Day 24 --
async def _incidents_full(since: float | None = None) -> list:
    params = {"full": "1"}
    if since is not None:
        params["since"] = str(since)
    try:
        r = await http.get(f"{config.BOT_URL}/incidents", params=params, timeout=10)
        r.raise_for_status()
        return r.json()
    except Exception as e:  # noqa: BLE001
        UPSTREAM.labels("incident-bot").inc()
        raise HTTPException(502, f"incident-bot: {type(e).__name__}: {str(e)[:200]}")


async def _jenkins_builds():
    if not (config.JENKINS_URL and config.JENKINS_USER and config.JENKINS_TOKEN):
        return None
    try:
        r = await http.get(f"{config.JENKINS_URL}/job/deploy-service/api/json",
                           params={"tree": "builds[number,result,timestamp]{0,400}"},
                           auth=(config.JENKINS_USER, config.JENKINS_TOKEN), timeout=8)
        r.raise_for_status()
        return r.json().get("builds", [])
    except Exception:  # noqa: BLE001
        UPSTREAM.labels("jenkins").inc()
        return None


async def _prom_value(q):
    try:
        d = await _prom(q)
        res = d.get("data", {}).get("result", [])
        return round(float(res[0]["value"][1]), 1) if res else None
    except Exception:  # noqa: BLE001
        return None


async def _prom_names(q):
    try:
        d = await _prom(q)
        return [r["metric"].get("alertname") for r in d.get("data", {}).get("result", [])]
    except Exception:  # noqa: BLE001
        return None


def _off(k):
    return f" offset {7 * k}d" if k else ""


_kpi_cache: dict = {"at": 0.0, "data": None}


@app.get("/api/kpis")
async def kpis_page(fresh: bool = False, c: Caller = Depends(caller)):
    """The seven Day 18 KPIs with a 4-week trend, and the incident table (kpis.py)."""
    if not fresh and _kpi_cache["data"] and time.time() - _kpi_cache["at"] < config.KPI_CACHE_S:
        return _kpi_cache["data"]
    ks = list(reversed(range(kpi.WEEKS)))           # oldest week first
    avail = 'clamp_max(100 * (1 - (1 - sum(increase(activation_requests_total{status="ok"}[30d]%s)) / clamp_min(sum(increase(activation_requests_total[30d]%s)), 1)) / 0.005), 100)'
    lat = 'clamp_max(100 * (1 - (1 - sum(increase(activation_latency_seconds_bucket{le="0.3"}[30d]%s)) / clamp_min(sum(increase(activation_latency_seconds_count[30d]%s)), 1)) / 0.01), 100)'
    fired_q = 'count by (alertname) (count_over_time(ALERTS{alertstate="firing"}[7d]%s))'
    incidents, runs, builds, rem, *promres = await asyncio.gather(
        _incidents_full(), db.runs(limit=200), _jenkins_builds(),
        _get("remediator", f"{config.REM_URL}/actions"),
        *[_prom_value(avail % (_off(k), _off(k))) for k in ks], *[_prom_value(lat % (_off(k), _off(k))) for k in ks],
        *[_prom_names(fired_q % _off(k)) for k in ks], return_exceptions=True)
    if isinstance(incidents, Exception):
        raise incidents
    rem_hist = rem if isinstance(rem, list) else (rem.get("actions") or rem.get("history") or []) if isinstance(rem, dict) else None
    w = kpi.WEEKS
    prom = {"eb_avail": promres[:w], "eb_lat": promres[w:2 * w], "fired": promres[2 * w:3 * w]}
    data = kpi.compute(incidents, runs if isinstance(runs, list) else [], rem_hist,
                       builds if isinstance(builds, list) else None, prom, await db.kb_feeding())
    _kpi_cache.update(at=time.time(), data=data)
    return data


# --- Step 1: the Game Day console -----------------------------------------------------------
@app.get("/api/gameday")
async def gameday_state(c: Caller = Depends(caller)):
    """Scenarios (never their steps), runs (sealed until Retro), and the knobs' live values — which
    are withheld while a sealed run is live: the console's own panel must not give the game away."""
    scs = gameday.load_scenarios()
    errors = scs.pop("_errors", {})
    runs = await db.runs(limit=20)
    live = await runner.sealed_run()
    knobs = {"sealed": True, "run": live["id"]} if live else await actions.read_knobs()
    return {"scenarios": [gameday.public_scenario(x) for x in scs.values()], "scenario_errors": errors,
            "runs": [gameday.public_run(r) for r in runs], "knobs": knobs, "sealed_run": live["id"] if live else None,
            "annotations": bool(config.GRAFANA_WRITE_TOKEN)}


def _run_id(run_id: str) -> str:
    if not re.fullmatch(r"run-[0-9TZ]{16}", run_id):
        raise HTTPException(400, "bad run id")
    return run_id


@app.post("/api/gameday/runs/{run_id}/retro")
async def gameday_retro(run_id: str, c: Caller = Depends(writer)):
    try:
        run = await runner.retro(_run_id(run_id), c.operator)
    except KeyError:
        raise HTTPException(404, f"no run {run_id}")
    return gameday.public_run(run)


@app.post("/api/gameday/runs/{run_id}/abort")
async def gameday_abort(run_id: str, c: Caller = Depends(writer)):
    n = await runner.abort(c.operator, "aborted from the console", _run_id(run_id))
    if not n:
        raise HTTPException(409, f"{run_id} is not running")
    return {"ok": True, "aborted": run_id}


@app.get("/api/gameday/runs/{run_id}/skeleton")
async def gameday_skeleton(run_id: str, c: Caller = Depends(caller)):
    """gameday/run-<ts>.md — only after Retro. scripts/245-gameday-run.sh saves it into the repo."""
    run = await db.run(_run_id(run_id))
    if not run:
        raise HTTPException(404, f"no run {run_id}")
    if not run.get("revealed_at"):
        raise HTTPException(409, "sealed — press Retro first")
    t0 = run["started_at"]
    end = max(run.get("reset_at") or 0, run.get("revealed_at") or 0, time.time() if not run.get("reset_at") else 0)
    feed = await db.feed_between(t0 - 30, end)
    incs = [i for i in await _incidents_full(since=t0 - 60) if (i.get("opened_at") or 0) <= end]
    md = gameday.skeleton(run, feed, sorted(incs, key=lambda i: i.get("opened_at") or 0))
    return Response(md, media_type="text/markdown; charset=utf-8",
                    headers={"Content-Disposition": f'inline; filename="{run_id}.md"'})


# --- Step 4: the knowledge base as cards, and the feeding rule --------------------------------
def _kb_entry(name: str, text: str) -> dict:
    """One card. Parsed like the bot parses it (kbparse); a file the parser refuses is still a card —
    with the error on it, so a broken entry is visible, not silently missing."""
    try:
        e = kbparse.parse(text, name)
    except kbparse.KBError as err:
        return {"file": name, "id": None, "title": name, "error": str(err), "tier": "", "services": [], "symptoms": [],
                "checks": [], "fix": None, "learned_from": [], "notes": "", "markdown": text}
    return {"file": name, "id": e["id"], "title": e["title"], "tier": str(e["tier"]), "services": e["services"],
            "symptoms": e["symptoms"], "checks": e["discriminating_checks"], "fix": e["fix"],
            "learned_from": e["learned_from"], "notes": e["notes"], "markdown": text}


@app.post("/api/incidents/{iid}/kb-feeding")
async def kb_feeding(iid: str, request: Request, c: Caller = Depends(writer)):
    """Day 17's rule, one click: KB updated (which entry) — or not needed, because … Audited."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", iid):
        raise HTTPException(400, "bad incident id")
    body = await request.json() or {}
    decision, kb_id, reason = body.get("decision"), (body.get("kb_id") or "").strip() or None, (body.get("reason") or "").strip() or None
    if decision == "updated":
        if not kb_id or not re.fullmatch(r"kb-[0-9]{3}", kb_id):
            raise HTTPException(422, "kb_id: the entry you updated or added (kb-NNN)")
        reason = None
    elif decision == "not_needed":
        try:
            reason = actions.prose_reason(reason, "reason")
        except actions.ParamError as e:
            raise HTTPException(422, f"{e} — why no KB change is needed ('because' is the rule)")
        kb_id = None
    else:
        raise HTTPException(422, "decision: updated or not_needed")
    row = await db.set_kb_feeding(incident=iid, operator=c.operator, decision=decision, kb_id=kb_id, reason=reason)
    await _audit(operator=c.operator, action="kb_feeding", params={"incident": iid, "decision": decision, "kb_id": kb_id},
                 tier=1, entrance=c.entrance, result="ok", detail=reason or kb_id or "")
    return row


@app.get("/api/kb-feeding")
async def kb_feeding_all(c: Caller = Depends(caller)):
    return await db.kb_feeding()


async def _needs_human() -> dict:
    """The Overview's 'needs a human': resolved incidents since the feeding rule started with no KB
    decision, and open incidents that look stale (open > 30 min, none of their alerts firing)."""
    since = float(await db.setting("kb_feeding_since", "0") or 0)
    feeding = await db.kb_feeding()
    # RESOLVED since the rule started, whenever opened (a week back is plenty: a ticket open longer than
    # that is a stale-close case, and the bot's since filter is on opened_at).
    incs = await _incidents_full(since=since - 7 * 86400)
    unfed = [{"id": i["id"], "service": i.get("service"), "resolved_at_iso": i.get("resolved_at_iso")}
             for i in incs if i.get("status") == "resolved" and (i.get("resolved_at") or 0) >= since and i["id"] not in feeding]
    stale = []
    firing = set(await _prom_names('count by (alertname) (ALERTS{alertstate="firing"})') or [])
    for i in await _open_incidents():
        if i.get("opened_at_iso") and i["opened_at_iso"] < time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 1800)) \
                and not (set(i.get("alerts") or []) & firing):
            stale.append({"id": i["id"], "service": i.get("service"), "alerts": i.get("alerts"), "opened_at_iso": i.get("opened_at_iso")})
    return {"kb_unfed": unfed, "stale_open": stale, "feeding_since_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since))}


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


# ---------------------------------------------------------------------- MCP --
# Day 23 Step 4: /mcp — the copilot's tools for any MCP client, behind the same bearer token.

mcp = _mcp_asgi = None                                # built in lifespan()
app.add_middleware(mcp_server.MCPGate, get_mcp_app=lambda: _mcp_asgi, token_ok=_token_ok)
