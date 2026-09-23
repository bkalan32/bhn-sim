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


def test_later_days_say_so(client):
    assert client.post("/api/chat", headers=AUTH, json={}).status_code == 501
    assert "Day 24" in client.get("/api/kpis", headers=AUTH).text
