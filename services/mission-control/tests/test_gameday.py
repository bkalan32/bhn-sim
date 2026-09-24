"""
Day 24 — the Game Day console, KPIs, reports, the KB as cards, closing stale incidents.

A fake kubectl keeps real state in a JSON file (env per Deployment/CronJob container), so a sealed
scenario's steps, the live knob reads and Reset all are tested against something that changes.
"""
import asyncio
import importlib.util
import json
import os
import sys
import tempfile
import textwrap
import time

import httpx
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
os.environ.update({"MC_TOKEN": "test-token", "DRY_RUN": "true", "DATA_DIR": tempfile.mkdtemp(prefix="mc-"),
                   "HEALTH_POLL_S": "3600", "BOT_URL": "http://127.0.0.1:9", "REM_URL": "http://127.0.0.1:9",
                   "PROM_URL": "http://127.0.0.1:9", "AM_URL": "http://127.0.0.1:9"})

from fastapi.testclient import TestClient  # noqa: E402

import actions  # noqa: E402
import app as mc  # noqa: E402
import gameday  # noqa: E402
import kbparse  # noqa: E402
import kpis  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}
K = {**AUTH, "X-Operator": "K", "X-Entrance": "button"}
REPO = os.path.join(HERE, "..", "..", "..")

FAKE_KUBECTL = r'''#!/usr/bin/env python3
import json, sys
state_path = sys.argv[0] + ".state.json"
st = json.load(open(state_path))
args = sys.argv[1:]
if args[:2] == ["-n", "payments"]:
    args = args[2:]
open(sys.argv[0] + ".log", "a").write(" ".join(args) + "\n")
verb = args[0]
if verb == "get":
    kind, name = args[1].split("/")
    containers = [{"name": c, "env": [{"name": k, "value": v} for k, v in env.items()]}
                  for c, env in st.get(f"{kind}/{name}", {}).items()]
    pod = {"spec": {"containers": containers}}
    obj = {"spec": {"jobTemplate": {"spec": {"template": pod}}}} if kind == "cronjob" else {"spec": {"template": pod}}
    print(json.dumps(obj)); sys.exit(0)
if verb == "set" and args[1] == "env":
    target, rest = args[2], args[3:]
    container = None
    if rest[:1] == ["-c"]:
        container, rest = rest[1], rest[2:]
    res = st.setdefault(target, {})
    container = container or next(iter(res), target.split("/")[1])
    env = res.setdefault(container, {})
    for kv in rest:
        k, v = kv.split("=", 1); env[k] = v
    json.dump(st, open(state_path, "w"))
    print(f"{target} env updated"); sys.exit(0)
print("unsupported", args); sys.exit(1)
'''

BASE_STATE = {"deployment/activation": {"activation": {"ERROR_RATE": "0.02"}},
              "deployment/egift": {"egift": {}},
              "cronjob/settlement": {"settlement": {"SETTLEMENT_FAIL_MODE": "none"}},
              "deployment/loadgen": {"activation": {"RATE_MULTIPLIER": "1"}, "egift": {"RATE_MULTIPLIER": "1"}}}

SCENARIO = textwrap.dedent("""
    id: test-quick
    title: "two quick faults"
    summary: "Something will break. Find it."
    steps:
      - at_seconds: 0
        action: set_fault
        params: {target: egift, knob: EMAIL_FAIL_RATE, value: "0.35"}
        note: "loud one"
      - at_seconds: 1
        action: set_fault
        params: {target: settlement, knob: SETTLEMENT_FAIL_MODE, value: silent}
        note: "quiet one"
""")


@pytest.fixture(scope="module")
def client():
    with TestClient(mc.app) as c:
        yield c


@pytest.fixture()
def cluster(monkeypatch, tmp_path):
    k = tmp_path / "kubectl"
    k.write_text(FAKE_KUBECTL); k.chmod(0o755)
    (tmp_path / "kubectl.state.json").write_text(json.dumps(BASE_STATE))
    gd = tmp_path / "gameday"; gd.mkdir()
    (gd / "test-quick.yaml").write_text(SCENARIO)
    (gd / "broken.yaml").write_text("id: broken\nsteps:\n  - {at_seconds: 0, action: scale, params: {service: egift, replicas: 0}}\n")
    monkeypatch.setattr(mc.config, "KUBECTL", str(k))
    monkeypatch.setattr(mc.config, "DRY_RUN", False)
    monkeypatch.setattr(mc.config, "GAMEDAY_DIR", str(gd))
    state = lambda: json.loads((tmp_path / "kubectl.state.json").read_text())
    log = lambda: (tmp_path / "kubectl.log").read_text() if (tmp_path / "kubectl.log").exists() else ""
    return state, log


def wait(pred, timeout=8):
    t = time.time() + timeout
    while time.time() < t:
        if pred():
            return True
        time.sleep(0.1)
    return False


# ----------------------------------------------------------------- scenarios --
def test_the_repo_scenarios_are_valid():
    scs = gameday.load_scenarios(os.path.join(REPO, "gameday"))
    assert "_errors" not in scs, scs.get("_errors")
    assert {"scenario-1", "scenario-2"} <= set(scs)
    s1 = scs["scenario-1"]["steps"]
    assert [(s["params"]["target"], s["params"]["knob"]) for s in s1] == [("egift", "EMAIL_FAIL_RATE"), ("settlement", "SETTLEMENT_FAIL_MODE")]


def test_a_broken_scenario_is_reported_not_skipped(cluster):
    scs = gameday.load_scenarios()
    assert "test-quick" in scs and "broken.yaml" in scs["_errors"] and "set_fault" in scs["_errors"]["broken.yaml"]


def test_the_console_never_shows_steps_before_a_run(client, cluster):
    d = client.get("/api/gameday", headers=AUTH).json()
    sc = next(s for s in d["scenarios"] if s["id"] == "test-quick")
    assert "steps" not in sc and "EMAIL_FAIL_RATE" not in json.dumps(d["scenarios"])
    assert d["knobs"]["egift"]["knobs"]["EMAIL_FAIL_RATE"] == {"value": "0.01", "set": False, "baseline": "0.01", "at_baseline": True}
    assert d["knobs"]["activation"]["knobs"]["ERROR_RATE"]["set"] is True


# ------------------------------------------------------------ a sealed run --
def test_a_sealed_run_injects_on_schedule_and_reveals_only_at_retro(client, cluster):
    state, log = cluster
    r = client.post("/api/actions/run_scenario", headers=K, json={"params": {"scenario": "test-quick"}, "reason": "game day"}).json()
    assert r["status"] == "pending_approval"                      # one approval for the whole schedule
    assert client.post("/api/actions/run_scenario", headers=K, json={"params": {"scenario": "nope"}}).status_code == 422
    token = r["token"]
    out = client.post(f"/api/approvals/{token}/approve", headers=K).json()
    assert out["status"] == "executed" and "sealed" in out["detail"]
    assert wait(lambda: state()["cronjob/settlement"]["settlement"]["SETTLEMENT_FAIL_MODE"] == "silent")
    assert state()["deployment/egift"]["egift"]["EMAIL_FAIL_RATE"] == "0.35"

    time.sleep(0.3)                                               # the schedule has now COMPLETED — still sealed
    d = client.get("/api/gameday", headers=AUTH).json()
    run = d["runs"][0]
    assert run["status"] == "sealed" and "steps" not in run
    assert d["knobs"] == {"sealed": True, "run": run["id"]}        # the console's own panel must not tell
    audit = client.get("/api/audit?limit=30", headers=AUTH).json()
    sealed = [a for a in audit if a["action"] == "scenario_step"]
    assert len(sealed) == 2 and all(set(a["params"]) == {"run", "step"} for a in sealed)
    assert all(a["approval_token"] == token and a["entrance"] == "scenario" for a in sealed)
    assert "EMAIL_FAIL_RATE" not in json.dumps(sealed)
    # no second run while this one is live
    r2 = client.post("/api/actions/run_scenario", headers=K, json={"params": {"scenario": "test-quick"}, "reason": "x"}).json()
    assert "still running" in client.post(f"/api/approvals/{r2['token']}/approve", headers=K).json()["detail"]
    assert client.get(f"/api/gameday/runs/{run['id']}/skeleton", headers=AUTH).status_code == 409

    rev = client.post(f"/api/gameday/runs/{run['id']}/retro", headers=K).json()
    assert rev["sealed"] is False and [s["params"]["knob"] for s in rev["steps"]] == ["EMAIL_FAIL_RATE", "SETTLEMENT_FAIL_MODE"]
    audit = client.get("/api/audit?limit=40", headers=AUTH).json()
    real = [a for a in audit if a["action"] == "scenario_step:set_fault"]
    assert len(real) == 2 and {a["params"]["knob"] for a in real} == {"EMAIL_FAIL_RATE", "SETTLEMENT_FAIL_MODE"}


def test_the_skeleton_has_the_injections_the_timeline_and_mttd(client, cluster, monkeypatch):
    run = client.get("/api/gameday", headers=AUTH).json()["runs"][0]
    fired = client.post(f"/api/gameday/runs/{run['id']}/retro", headers=K).json()["steps"][0]
    inc = {"id": "INC-9-aaaa", "service": "egift", "alerts": ["EgiftHighErrorRate"], "status": "open",
           "first_alert_at": None, "opened_at": time.time(), "opened_at_iso": "2026-09-24T18:00:00Z"}

    async def fake_incidents(since=None):
        rr = await mc.db.run(run["id"])
        f = rr["steps"][0]["fired_at"]
        return [{**inc, "first_alert_at": f + 150, "first_alert_at_iso": "2026-09-24T18:02:30Z"}]
    monkeypatch.setattr(mc, "_incidents_full", fake_incidents)
    md = client.get(f"/api/gameday/runs/{run['id']}/skeleton", headers=AUTH).text
    assert "EMAIL_FAIL_RATE=0.35" in md and "| INC-9-aaaa |" in md and "**150 s**" in md
    assert "Terminal:" in md and fired["state"] == "fired"


def test_reset_all_puts_every_knob_back_and_aborts_a_run(client, cluster):
    state, log = cluster
    r = client.post("/api/actions/set_fault", headers=K, json={"params": {"target": "activation", "knob": "FRAUD_SVC_DOWN", "value": "true"}, "reason": "t"}).json()
    client.post(f"/api/approvals/{r['token']}/approve", headers=K)
    assert state()["deployment/activation"]["activation"]["FRAUD_SVC_DOWN"] == "true"
    out = client.post("/api/actions/reset_faults", headers=K, json={}).json()
    assert out["status"] == "executed" and "FRAUD_SVC_DOWN true→false" in out["detail"]
    assert state()["deployment/activation"]["activation"]["FRAUD_SVC_DOWN"] == "false"
    assert state()["deployment/activation"]["activation"]["ERROR_RATE"] == "0.02"        # untouched: at baseline
    again = client.post("/api/actions/reset_faults", headers=K, json={}).json()
    assert "already at baseline" in again["detail"]


def test_game_day_annotations_never_carry_a_service_tag(monkeypatch):
    """The bot's recent_deploys reads annotations BY SERVICE TAG: a game-day marker there would hand the
    answer to the hypothesis (Day 10's Eval 3-leak)."""
    sent = []

    def grafana(req):
        sent.append(json.loads(req.content) if req.content else {})
        return httpx.Response(200, json={"id": 7})
    monkeypatch.setattr(mc.config, "GRAFANA_WRITE_TOKEN", "t")
    monkeypatch.setattr(mc.config, "DRY_RUN", False)

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(grafana)) as h:
            r = gameday.Runner(None, lambda: h, None, lambda *a: None)
            return await r.annotate("run-20260924T180000Z", "step 1 (sealed)", time.time()), await r.reannotate(7, "revealed")
    assert asyncio.run(go()) == (7, True)
    assert sent[0]["tags"] == ["gameday", "run-20260924T180000Z"]
    assert not set(sent[0]["tags"]) & set(actions.SERVICES) and "sealed" in sent[0]["text"]


# ---------------------------------------------------------------------- KPIs --
def test_mttd_is_computed_from_the_injection_and_hand_closed_incidents_leave_mttr():
    now = time.time()
    run = {"id": "run-x", "steps": [{"n": 1, "state": "fired", "fired_at": now - 3000,
                                     "params": {"target": "activation", "knob": "FRAUD_SVC_DOWN", "value": "true"}}]}
    incs = [
        {"id": "A", "service": "egift", "status": "resolved", "alerts": ["EgiftHighErrorRate"], "opened_at": now - 2800,
         "first_alert_at": now - 2850, "resolved_at": now - 2000, "duration_min": 13.3, "opened_at_iso": "x"},
        {"id": "B", "service": "platform", "status": "resolved", "alerts": ["PlatformPodRestarting"], "opened_at": now - 90000,
         "first_alert_at": now - 90000, "resolved_at": now - 100, "duration_min": 1498.3, "closed_by_human": {"by": "K", "reason": "reboot"},
         "opened_at_iso": "y"},
        {"id": "C", "service": "activation", "status": "resolved", "alerts": ["ActivationHighErrorRate"], "opened_at": now - 5000,
         "first_alert_at": now - 5000, "resolved_at": now - 4000, "duration_min": 16.7, "opened_at_iso": "z",
         "timeline": [{"event": "note", "text": "drill: fault injected at " + time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 5120))}]},
    ]
    d = kpis.compute(incs, [run], [], None, {}, {"A": {"decision": "updated", "kb_id": "kb-001"}}, now=now)
    t = {x["key"]: x for x in d["tiles"]}
    assert len(t["mttd"]["trend"]) == 4 and 135 <= t["mttd"]["value"] <= 136      # (150 + ~120) / 2
    rows = {r["id"]: r for r in d["incidents"]}
    assert rows["A"]["ttd_s"] == 150 and rows["A"]["ttd_source"].startswith("run-x step 1")
    assert rows["C"]["ttd_source"] == "drill note" and rows["B"]["ttd_s"] is None
    assert t["mttr"]["value"] == 15.0 and "1 closed by hand" in t["mttr"]["detail"]  # 1498 min is not an outage
    assert rows["A"]["kb"] == "updated" and t["deploys"]["value"] is None and "Jenkins" in t["deploys"]["detail"]
    assert "1 closed by hand" in t["mttr"]["detail"] and all(x["definition"] for x in d["tiles"])


def test_an_injection_only_explains_incidents_on_services_it_reaches():
    run = {"id": "r", "steps": [{"n": 1, "state": "fired", "fired_at": 1000.0, "params": {"target": "egift", "knob": "EMAIL_FAIL_RATE", "value": "0.3"}}]}
    assert gameday.injection_for({"service": "egift", "first_alert_at": 1200.0}, [run])["step"] == 1
    assert gameday.injection_for({"service": "activation", "first_alert_at": 1200.0}, [run]) is None   # egift does not break activation
    assert gameday.injection_for({"service": "egift", "first_alert_at": 900.0}, [run]) is None        # before the fault


# ------------------------------------------------------------------------ KB --
def test_kb_parser_mirrors_the_bot():
    spec = importlib.util.spec_from_file_location("botkb", os.path.join(REPO, "services", "incident-bot", "kb.py"))
    botkb = importlib.util.module_from_spec(spec); spec.loader.exec_module(botkb)
    kb_dir = os.path.join(REPO, "kb")
    for f in sorted(os.listdir(kb_dir)):
        if not f.endswith(".md") or f == "README.md":
            continue
        text = open(os.path.join(kb_dir, f)).read()
        assert kbparse.parse(text, f) == botkb.parse(text, f), f


def test_kb_cards_have_lists_even_where_yaml_would_choke(client, cluster, monkeypatch, tmp_path):
    kb_dir = os.path.join(REPO, "kb")
    data = {f: open(os.path.join(kb_dir, f)).read() for f in os.listdir(kb_dir) if f.endswith(".md")}
    cm = tmp_path / "cm.json"; cm.write_text(json.dumps({"data": data}))
    fake = tmp_path / "kubectl-cm"; fake.write_text(f"#!/bin/sh\ncat {cm}\n"); fake.chmod(0o755)
    monkeypatch.setattr(mc.config, "KUBECTL", str(fake))
    cards = {c["id"]: c for c in client.get("/api/kb", headers=AUTH).json()}
    assert None not in cards and len(cards) >= 7
    zero = next(c for c in cards.values() if "zero" in c["file"])   # the entry YAML refuses
    assert zero["symptoms"] and zero["checks"] and zero["learned_from"]


def test_the_feeding_rule_needs_an_entry_or_a_reason(client):
    assert client.post("/api/incidents/INC-1-a/kb-feeding", headers=K, json={"decision": "updated"}).status_code == 422
    assert client.post("/api/incidents/INC-1-a/kb-feeding", headers=K, json={"decision": "not_needed", "reason": "meh"}).status_code == 422
    ok = client.post("/api/incidents/INC-1-a/kb-feeding", headers=K, json={"decision": "not_needed", "reason": "stale reboot ticket, no fault"}).json()
    assert ok["decision"] == "not_needed"
    assert client.get("/api/kb-feeding", headers=AUTH).json()["INC-1-a"]["reason"].startswith("stale")
    assert any(a["action"] == "kb_feeding" for a in client.get("/api/audit?limit=10", headers=AUTH).json())


def test_needs_a_human_lists_unfed_and_stale_incidents(client, monkeypatch):
    now = time.time()

    async def full(since=None):
        return [{"id": "INC-2-b", "status": "resolved", "service": "egift", "resolved_at_iso": "x", "opened_at": now - 86400, "resolved_at": now},
                {"id": "INC-1-a", "status": "resolved", "service": "egift", "opened_at": now, "resolved_at": now},
                {"id": "INC-0-z", "status": "resolved", "service": "egift", "opened_at": now - 90000, "resolved_at": now - 86000}]

    async def open_():
        return [{"id": "INC-3-c", "service": "platform", "alerts": ["PlatformPodRestarting"], "opened_at_iso": "2026-09-23T19:54:51Z"},
                {"id": "INC-4-d", "service": "activation", "alerts": ["ActivationHighErrorRate"], "opened_at_iso": "2026-09-23T19:54:51Z"}]

    async def names(q):
        return ["ActivationHighErrorRate"]
    monkeypatch.setattr(mc, "_incidents_full", full)
    monkeypatch.setattr(mc, "_open_incidents", open_)
    monkeypatch.setattr(mc, "_prom_names", names)
    nh = client.get("/api/overview", headers=AUTH).json()["needs_human"]["data"]
    assert [i["id"] for i in nh["kb_unfed"]] == ["INC-2-b"]                  # INC-1-a was fed above
    assert [i["id"] for i in nh["stale_open"]] == ["INC-3-c"]                 # INC-4-d's alert still fires


# ------------------------------------------------------------ close incident --
def test_closing_is_refused_while_its_alert_fires(monkeypatch):
    monkeypatch.setattr(mc.config, "DRY_RUN", False)
    firing = {"v": True}

    def up(req):
        if req.url.path.endswith("/close"):
            return httpx.Response(200, json={"ok": True})
        if "/api/v1/query" in req.url.path:
            res = [{"metric": {"alertname": "PlatformPodRestarting"}, "value": [0, "1"]}] if firing["v"] else []
            return httpx.Response(200, json={"status": "success", "data": {"result": res}})
        return httpx.Response(200, json={"id": "INC-3-c", "status": "open", "alerts": ["PlatformPodRestarting"]})

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(up)) as h:
            return await actions.x_close_incident(h, {"incident": "INC-3-c", "why": "reboot lost the resolved webhook"}, "K")
    ok, detail = asyncio.run(go())
    assert not ok and "still firing" in detail
    firing["v"] = False
    ok, detail = asyncio.run(go())
    assert ok
    with pytest.raises(actions.ParamError):
        actions.validate("close_incident", {"incident": "INC-3-c", "why": "stale"})


# ------------------------------------------------------------------ reports --
def test_a_report_is_gradeable(client):
    row = client.post("/api/eval", headers=K, json={"report": "2026-09-24", "verdict": "up", "comment": "boring, as it should be"}).json()
    assert row["draft"] == "report" and row["incident"] == "report:2026-09-24"
    assert client.post("/api/eval", headers=K, json={"report": "../etc", "verdict": "up"}).status_code == 422


def test_a_completed_run_stays_sealed_until_reset_all(client, cluster):
    """Found while testing: once the last step fired the run became 'done' and the knob panel showed the
    injected values — the seal must hold until Retro or Reset all, not until the schedule ends."""
    state, _ = cluster
    r = client.post("/api/actions/run_scenario", headers=K, json={"params": {"scenario": "test-quick"}, "reason": "g"}).json()
    client.post(f"/api/approvals/{r['token']}/approve", headers=K)
    assert wait(lambda: state()["cronjob/settlement"]["settlement"]["SETTLEMENT_FAIL_MODE"] == "silent")
    time.sleep(0.3)
    assert client.get("/api/gameday", headers=AUTH).json()["knobs"].get("sealed") is True
    out = client.post("/api/actions/reset_faults", headers=K, json={}).json()
    assert "EMAIL_FAIL_RATE 0.35→0.01" in out["detail"]
    d = client.get("/api/gameday", headers=AUTH).json()
    assert "sealed" not in d["knobs"] and d["knobs"]["egift"]["knobs"]["EMAIL_FAIL_RATE"]["at_baseline"]
    assert d["runs"][0]["reset_at_iso"] and d["runs"][0]["status"] == "sealed"   # still unrevealed: Retro shows it


def test_the_skeleton_clock_and_what_the_timeline_leaves_out():
    assert gameday._clock(1000.0, 1118.0).endswith("-1m58s") and gameday._clock(1070.0, 1000.0).endswith("+1m10s")
    revealed = {"kind": "audit", "data": {"action": "scenario_step:set_fault", "tier": 2, "params": {}, "operator": "K", "result": "ok", "entrance": "scenario"}}
    assert gameday._feed_line(revealed) is None                      # it is in the injected table, at its real time
    note = {"kind": "audit", "data": {"action": "note", "tier": 1, "params": {"incident": "I"}, "operator": "K", "result": "ok", "entrance": "button"}}
    assert "note" in gameday._feed_line(note)


def test_a_fresh_tab_gets_the_kept_feed(client):
    rows = client.get("/api/feed?limit=50", headers=AUTH).json()
    kinds = {r["kind"] for r in rows}
    assert "audit" in kinds and not any(str(r["data"].get("action", "")).startswith("tool:") for r in rows)
    assert rows == sorted(rows, key=lambda r: -r["id"])
