"""
Day 21 — the properties the graduation bar asks for, tested before anything is deployed.

Runs the real app in-process (DRY_RUN=true: every executor reports what it would do), with a
temporary database and fake upstreams where a route needs one.
"""
import asyncio
import json
import os
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
os.environ.update({"MC_TOKEN": "test-token", "DRY_RUN": "true", "DATA_DIR": tempfile.mkdtemp(prefix="mc-"),
                   "HEALTH_POLL_S": "3600", "BOT_URL": "http://127.0.0.1:9", "REM_URL": "http://127.0.0.1:9",
                   "PROM_URL": "http://127.0.0.1:9", "AM_URL": "http://127.0.0.1:9"})

from fastapi.testclient import TestClient  # noqa: E402

import actions  # noqa: E402
import app as mc  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}
K = {**AUTH, "X-Operator": "K", "X-Entrance": "button"}


@pytest.fixture(scope="module")
def client():
    with TestClient(mc.app) as c:
        yield c


# ---------------------------------------------------------------- Step 4: auth --
@pytest.mark.parametrize("path", ["/api/overview", "/api/actions", "/api/audit", "/api/approvals", "/api/incidents"])
def test_every_api_route_401s_without_the_token(client, path):
    assert client.get(path).status_code == 401
    assert client.get(path, headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_writes_need_an_operator(client):
    r = client.post("/api/actions/rerun_settlement", headers=AUTH, json={})
    assert r.status_code == 400 and "X-Operator" in r.text


def test_health_and_metrics_are_open(client):
    assert client.get("/healthz").status_code == 200
    assert client.get("/metrics").status_code == 200


def test_auth_fails_closed_with_no_token_configured(client, monkeypatch):
    monkeypatch.setattr(mc.config, "MC_TOKEN", "")
    assert client.get("/api/actions", headers={"Authorization": "Bearer "}).status_code == 401
    assert client.get("/api/actions", headers=AUTH).status_code == 401


# ---------------------------------------------------------- Step 3: the catalog --
def test_catalog_lists_tiers_and_knobs(client):
    d = client.get("/api/actions", headers=AUTH).json()
    ids = {a["id"]: a for a in d["actions"]}
    assert {"rerun_settlement", "delete_crashlooping_pod", "run_drift_check", "generate_report", "note"} <= set(ids)
    assert all(ids[a]["tier"] == 2 for a in ("rollback", "scale", "deploy", "silence_alert", "set_fault"))
    assert "RATE_MULTIPLIER" in ids["set_fault"]["knobs"]["loadgen-activation"]


def test_tier1_executes_and_audits(client):
    r = client.post("/api/actions/rerun_settlement", headers=K, json={})
    assert r.status_code == 200 and r.json()["status"] == "executed"
    assert "create job settlement-manual-" in r.json()["detail"] and "--from=cronjob/settlement" in r.json()["detail"]
    row = client.get("/api/audit?limit=1", headers=AUTH).json()[0]
    assert (row["action"], row["tier"], row["operator"], row["entrance"], row["result"]) == ("rerun_settlement", 1, "K", "button", "ok")


def test_tier2_queues_and_does_nothing_without_approval(client):
    r = client.post("/api/actions/rollback", headers=K, json={"params": {"service": "activation"}, "reason": "bad release"})
    d = r.json()
    assert d["status"] == "pending_approval" and d["token"].startswith("rollback-")
    rows = client.get("/api/audit?action=rollback", headers=AUTH).json()
    assert [x["result"] for x in rows] == ["pending"]                         # queued, NOT executed
    assert any(a["token"] == d["token"] for a in client.get("/api/approvals", headers=AUTH).json())


def test_approval_is_single_use_and_records_who(client):
    tok = client.post("/api/actions/scale", headers=K, json={"params": {"service": "egift", "replicas": 1}}).json()["token"]
    first = client.post(f"/api/approvals/{tok}/approve", headers={**K, "X-Operator": "reviewer"})
    assert first.status_code == 200 and first.json()["status"] == "executed"
    assert "scale deployment/egift --replicas=1" in first.json()["detail"]
    assert first.json()["approved_by"] == "reviewer" and first.json()["requested_by"] == "K"
    second = client.post(f"/api/approvals/{tok}/approve", headers=K)          # the double-click
    assert second.status_code in (404, 502)                                    # ours is gone; remediator unreachable in tests
    row = [x for x in client.get("/api/audit?action=scale", headers=AUTH).json() if x["result"] == "ok"][0]
    assert row["approval_token"] == tok and row["operator"] == "reviewer"


def test_the_ai_can_propose_but_never_approve(client):
    cop = {**AUTH, "X-Operator": "copilot", "X-Entrance": "copilot"}
    tok = client.post("/api/actions/rollback", headers=cop, json={"params": {"service": "egift"}}).json()["token"]
    assert client.post(f"/api/approvals/{tok}/approve", headers=cop).status_code == 403
    assert client.post(f"/api/approvals/{tok}/approve", headers={**cop, "X-Entrance": "mcp"}).status_code == 403
    assert any(a["token"] == tok for a in client.get("/api/approvals", headers=AUTH).json())   # still waiting for a human
    assert client.post(f"/api/approvals/{tok}/decline", headers=K).json()["status"] == "declined"


def test_bad_params_are_rejected_before_the_queue(client):
    for body in ({"params": {"service": "database"}}, {"params": {"service": "activation", "extra": 1}}):
        assert client.post("/api/actions/rollback", headers=K, json=body).status_code == 422
    r = client.post("/api/actions/set_fault", headers=K, json={"params": {"target": "activation", "knob": "ERROR_RATE", "value": "5"}})
    assert r.status_code == 422 and "between 0.0 and 1.0" in r.text
    r = client.post("/api/actions/set_fault", headers=K, json={"params": {"target": "activation", "knob": "PATH", "value": "/tmp"}})
    assert r.status_code == 422
    assert client.post("/api/actions/drop_database", headers=K, json={}).status_code == 404


def test_set_fault_builds_the_per_container_command():
    p = actions.validate("set_fault", {"target": "loadgen-activation", "knob": "RATE_MULTIPLIER", "value": "0"})
    ok, detail = asyncio.run(actions.x_set_fault(None, p, "K"))
    assert ok and "set env deployment/loadgen -c activation RATE_MULTIPLIER=0" in detail


def test_kubectl_allow_list_refuses_other_verbs():
    ok, detail = asyncio.run(actions.kubectl("delete", "deployment/activation"))
    assert not ok and "not on the allow-list" in detail


def test_deploy_change_cause_cannot_smuggle_shell():
    with pytest.raises(actions.ParamError):
        actions.validate("deploy", {"service": "activation", "change_cause": "x'; rm -rf / #"})


# --------------------------------------------------------- Step 2/5: the feed --
def test_webhook_publishes_to_subscribers(client):
    b = mc.broker
    q = b.subscribe()
    try:
        body = {"status": "firing", "alerts": [{"status": "firing", "labels": {"alertname": "ActivationHighErrorRate",
                "service": "activation", "severity": "critical"}, "annotations": {"summary": "errors"}, "startsAt": "2026-09-23T19:00:00Z"}]}
        # the module's client — a second TestClient would run the lifespan again and close the db
        assert client.post("/hooks/alertmanager", json=body).status_code == 200
        ev = q.get_nowait()
        while ev["kind"] != "alert":
            ev = q.get_nowait()
        assert ev["data"]["alertname"] == "ActivationHighErrorRate" and ev["data"]["severity"] == "critical"
    finally:
        b.unsubscribe(q)


def test_a_slow_subscriber_never_blocks_the_publisher():
    from events import Broker
    b = Broker(maxsize=3)
    q = b.subscribe()
    for i in range(10):
        b.publish("alert", {"n": i})
    got = [q.get_nowait()["data"]["n"] for _ in range(q.qsize())]
    assert got == [7, 8, 9]                                                 # oldest dropped, newest kept


def test_overview_degrades_per_tile(client):
    d = client.get("/api/overview", headers=AUTH).json()
    assert d["health"]["ok"] is False and "prometheus" in d["health"]["error"]   # upstreams down in the test
    assert d["approvals"]["ok"] is True                                          # our own data still there
    assert d["ms"] < 5000


def test_chat_without_a_key_says_so(client, monkeypatch):
    monkeypatch.setattr(mc.config, "ANTHROPIC_API_KEY", "")
    r = client.post("/api/chat", headers=K, json={"message": "hi"})
    assert r.status_code == 503 and "ai-keys" in r.text


# ------------------------------------------------------------------ Day 22 --
def test_eval_rows_are_written_and_audited(client):
    r = client.post("/api/eval", headers=K, json={"incident": "INC-1-abcd", "draft": "resolved", "verdict": "up"})
    assert r.status_code == 200 and r.json()["verdict"] == "up"
    rows = client.get("/api/eval?incident=INC-1-abcd", headers=AUTH).json()
    assert rows[0]["operator"] == "K" and rows[0]["draft"] == "resolved"
    audit = client.get("/api/audit?action=rate_draft", headers=AUTH).json()
    assert audit[0]["params"] == {"draft": "resolved", "incident": "INC-1-abcd", "verdict": "up"}


@pytest.mark.parametrize("body", [{"incident": "INC-1", "draft": "poem", "verdict": "up"},
                                  {"incident": "INC-1", "draft": "open", "verdict": "meh"},
                                  {"incident": "../etc", "draft": "open", "verdict": "up"}])
def test_eval_rejects_bad_input(client, body):
    assert client.post("/api/eval", headers=K, json=body).status_code == 422


def test_eval_needs_an_operator(client):
    assert client.post("/api/eval", headers=AUTH, json={"incident": "INC-1", "draft": "open", "verdict": "up"}).status_code == 400


def test_ui_config_is_behind_the_token_and_has_no_secrets(client):
    assert client.get("/api/config").status_code == 401
    d = client.get("/api/config", headers=AUTH).json()
    assert d["grafana_url"].startswith("http") and len(d["embed_panels"]) >= 4
    assert "token" not in json.dumps(d).lower()


def test_root_without_a_built_ui_says_so(client, monkeypatch):
    monkeypatch.setattr(mc.config, "UI_DIR", "/nonexistent")
    assert client.get("/").json()["ui"] == "not built into this image"


def test_root_serves_the_ui_with_a_csp(client, monkeypatch, tmp_path):
    (tmp_path / "index.html").write_text("<!doctype html><div id=root></div>")
    monkeypatch.setattr(mc.config, "UI_DIR", str(tmp_path))
    r = client.get("/")
    assert r.status_code == 200 and "id=root" in r.text
    csp = r.headers["content-security-policy"]
    assert "frame-src http://localhost:3000" in csp and "connect-src 'self'" in csp and "script-src 'self'" in csp


def test_poller_announces_changes_not_the_present(monkeypatch):
    """First pass primes; only a NEW incident is 'opened', a vanished one 'resolved'."""
    from events import Broker
    b = Broker(); q = b.subscribe()
    monkeypatch.setattr(mc, "broker", b)
    monkeypatch.setattr(mc, "seen", mc._Seen())
    state = {"open": [{"id": "INC-1", "service": "activation"}]}

    async def fake_open():
        return state["open"]

    async def fake_get(name, url, **kw):
        return {"id": url.rsplit("/", 1)[1], "status": "resolved", "duration_min": 4.0, "service": "activation"}
    monkeypatch.setattr(mc, "_open_incidents", fake_open)
    monkeypatch.setattr(mc, "_get", fake_get)
    asyncio.run(mc._watch_incidents())
    assert q.empty()                                                       # primed, nothing announced
    state["open"] = [{"id": "INC-2", "service": "egift"}]
    asyncio.run(mc._watch_incidents())
    got = [q.get_nowait()["data"] for _ in range(q.qsize())]
    assert {(e["event"], e["id"]) for e in got} == {("opened", "INC-2"), ("resolved", "INC-1")}


def test_metric_queries_mirror_the_bot():
    """config.METRIC_QUERIES is a copy of the bot's enrich.QUERIES (the deep links must open the
    query that produced the number). The bot's source is in the same checkout; drift fails here."""
    import ast
    src = open(os.path.join(HERE, "..", "..", "incident-bot", "enrich.py")).read()
    node = next(n for n in ast.parse(src).body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "QUERIES")
    assert ast.literal_eval(node.value) == mc.config.METRIC_QUERIES


def test_kb_route_parses_a_real_sized_configmap(client, monkeypatch, tmp_path):
    """CORRECTIONS-DAY22 B1: kubectl() trimmed every output to its last 1500 chars (right for audit
    rows), which cut the ~20 KB KB ConfigMap's JSON from the front — /api/kb was a 500 since Day 21."""
    kb_dir = os.path.join(HERE, "..", "..", "..", "kb")
    data = {os.path.basename(f): open(os.path.join(kb_dir, f)).read() for f in os.listdir(kb_dir) if f.endswith(".md")}
    assert len(json.dumps(data)) > 1500
    fake = tmp_path / "kubectl"
    (tmp_path / "cm.json").write_text(json.dumps({"data": data}))
    fake.write_text(f"#!/bin/sh\ncat {tmp_path / 'cm.json'}\n"); fake.chmod(0o755)
    monkeypatch.setattr(mc.config, "KUBECTL", str(fake))
    monkeypatch.setattr(mc.config, "DRY_RUN", False)
    r = client.get("/api/kb", headers=AUTH)
    assert r.status_code == 200
    ids = {e["id"] for e in r.json()}
    assert "kb-001" in ids and all(e["fix"] for e in r.json())


def test_a_deploy_is_announced_once_even_if_grafana_ignores_the_time_filter(monkeypatch):
    """CORRECTIONS-DAY22 B2: with `from` alone Grafana returned every annotation on every pass."""
    from events import Broker
    b = Broker(); q = b.subscribe()
    monkeypatch.setattr(mc, "broker", b)
    monkeypatch.setattr(mc, "seen", mc._Seen())
    monkeypatch.setattr(mc.config, "GRAFANA_TOKEN", "x")
    ann = []

    class R:
        def raise_for_status(self): pass
        def json(self): return list(ann)            # ignores from/to, like the real one did

    class H:
        async def get(self, *a, **kw): return R()
    monkeypatch.setattr(mc, "http", H())
    asyncio.run(mc._watch_deploys())                # primes
    import time as _t
    ann.append({"time": int(_t.time() * 1000) + 5, "tags": ["deploy", "egift"], "text": "build 58"})
    for _ in range(4):
        asyncio.run(mc._watch_deploys())
    got = [q.get_nowait()["data"] for _ in range(q.qsize())]
    assert [g["text"] for g in got] == ["build 58"]
