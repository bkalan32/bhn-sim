"""
Day 23 — the copilot, the proposal path and the MCP server, tested without a model: the model's
turns are scripted (copilot._stream_round is replaced), everything else is the real code path —
the tool loop, the budget, the audit rows, the approval queue, the SSE stream, the MCP transport.
"""
import ast
import asyncio
import json
import os
import sys
import tempfile

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
import copilot  # noqa: E402

AUTH = {"Authorization": "Bearer test-token"}
K = {**AUTH, "X-Operator": "K", "X-Entrance": "button"}
MCP_H = {**AUTH, "Accept": "application/json, text/event-stream", "Content-Type": "application/json",
         "X-Operator": "claude-code", "mcp-protocol-version": "2025-06-18"}


@pytest.fixture(scope="module")
def client():
    with TestClient(mc.app) as c:
        yield c


def script(rounds):
    """Replace the model: each call returns the next scripted turn, emitting its text like the stream would."""
    it = iter(rounds)

    async def fake(http, messages, emit):
        r = next(it)
        for b in r["content"]:
            if b["type"] == "text":
                await emit("text", {"text": b["text"]})
        return {"stop_reason": r.get("stop_reason", "end_turn"), "usage": {"input_tokens": 100, "output_tokens": 20},
                "model": "claude-opus-5-5", "content": r["content"]}
    return fake


def tool_use(i, name, inp):
    return {"type": "tool_use", "id": f"tu_{i}", "name": name, "input": inp}


# --------------------------------------------------------------- the contract --
def test_platform_facts_mirror_the_bot():
    src = open(os.path.join(HERE, "..", "..", "incident-bot", "ai.py")).read()
    node = next(n for n in ast.parse(src).body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "PLATFORM_FACTS")
    assert ast.literal_eval(node.value) == copilot.PLATFORM_FACTS


def test_read_tools_are_strict_and_every_tool_is_closed():
    def closed(s):
        return s.get("type") != "object" or (s.get("additionalProperties") is False and all(closed(v) for v in s.get("properties", {}).values()))

    def optional(s):
        if s.get("type") != "object":
            return 0
        props = s.get("properties", {})
        return len(set(props) - set(s.get("required", []))) + sum(optional(v) for v in props.values())
    tools = copilot.api_tools()
    assert all(closed(t["input_schema"]) for t in tools)
    strict = [t for t in tools if t.get("strict")]
    assert {t["name"] for t in tools} - {t["name"] for t in strict} == {"propose_action"}   # CORRECTIONS-DAY23 B2
    # every optional field doubles the grammar the API compiles for strict tools: keep the total tiny
    assert sum(optional(t["input_schema"]) for t in strict) <= 4
    assert tools[-1]["cache_control"] == {"type": "ephemeral"}          # the cache breakpoint after the tool list
    prop = next(t for t in tools if t["name"] == "propose_action")
    assert prop["input_schema"]["properties"]["action_id"]["enum"] == sorted(actions.CATALOG)
    assert not any("approve" in t["name"] for t in tools)                # there is no tool that approves


@pytest.mark.parametrize("args,why", [("delete pod x -n payments", "not permitted"), ("get secret ai-keys -n payments", "off limits"),
                                      ("get cm kb -n payments", "off limits"), ("rollout undo deployment/activation", "not permitted"),
                                      ("get pods -n kube-system", "not part of this platform"), ("get pods -A", "all-namespaces"),
                                      ("exec -it x -- sh", "not permitted"), ("get pods --token=x", "not permitted")])
def test_kubectl_allow_list(args, why):
    argv, reason = copilot.check_kubectl(args)
    assert argv is None and why in reason


def test_kubectl_defaults_namespace_and_caps_logs():
    argv, _ = copilot.check_kubectl("logs deploy/activation")
    assert argv[-3:] == ["-n", "payments", "--tail=80"] or ("--tail=80" in argv and "payments" in argv)


# ------------------------------------------------------------- the stream parser --
SSE = [
    {"type": "message_start", "message": {"model": "claude-opus-5-5", "usage": {"input_tokens": 50, "cache_read_input_tokens": 900}}},
    {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}},
    {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "check alerts"}},
    {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "SIG"}},
    {"type": "content_block_stop", "index": 0},
    {"type": "content_block_start", "index": 1, "content_block": {"type": "fallback", "from": {"model": "claude-opus-5-5"}, "to": {"model": "claude-opus-4-8"}}},
    {"type": "content_block_stop", "index": 1},
    {"type": "content_block_start", "index": 2, "content_block": {"type": "text", "text": ""}},
    {"type": "content_block_delta", "index": 2, "delta": {"type": "text_delta", "text": "Looking."}},
    {"type": "content_block_stop", "index": 2},
    {"type": "content_block_start", "index": 3, "content_block": {"type": "tool_use", "id": "tu_1", "name": "query_prometheus", "input": {}}},
    {"type": "content_block_delta", "index": 3, "delta": {"type": "input_json_delta", "partial_json": "{\"query\": \"up"}},
    {"type": "content_block_delta", "index": 3, "delta": {"type": "input_json_delta", "partial_json": "\"}"}},
    {"type": "content_block_stop", "index": 3},
    {"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {"output_tokens": 42}},
    {"type": "message_stop"},
]


def test_stream_parser_keeps_thinking_intact_and_drops_the_fallback_marker(monkeypatch):
    body = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in SSE)
    sent = {}

    def handler(req):
        sent.update(json.loads(req.content))
        sent["beta"] = req.headers.get("anthropic-beta")
        return httpx.Response(200, text=body, headers={"content-type": "text/event-stream"})
    monkeypatch.setattr(copilot.config, "ANTHROPIC_API_KEY", "k")
    events = []

    async def emit(k, d):
        events.append(k)

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as h:
            return await copilot._stream_round(h, [{"role": "user", "content": "q"}], emit)
    r = asyncio.run(go())
    assert [b["type"] for b in r["content"]] == ["thinking", "text", "tool_use"]      # the marker is not resent
    assert r["content"][0] == {"type": "thinking", "thinking": "check alerts", "signature": "SIG"}
    assert r["content"][2]["input"] == {"query": "up"}
    assert r["stop_reason"] == "tool_use" and r["model"] == "claude-opus-4-8"
    assert r["usage"]["output_tokens"] == 42 and r["usage"]["cache_read_input_tokens"] == 900
    assert {"thinking", "fallback", "text"} <= set(events)
    assert sent["thinking"] == {"type": "adaptive", "display": "summarized"} and "temperature" not in sent
    assert sent["system"][0]["cache_control"] == {"type": "ephemeral"} and sent["stream"] is True
    assert sent["fallbacks"] == "default" and sent["beta"] == "server-side-fallback-2026-07-01"


# --------------------------------------------------------------- the loop --
def test_a_proposal_queues_an_approval_and_runs_nothing(client, monkeypatch):
    monkeypatch.setattr(copilot, "_stream_round", script([
        {"stop_reason": "tool_use", "content": [tool_use(1, "propose_action", {"action_id": "rollback", "params": {"service": "activation", "incident": ""},
                                                                              "reason": "errors began 3 min after build 57"})]},
        {"content": [{"type": "text", "text": "I proposed a rollback; a human decides."}]},
    ]))
    conv = mc.conversations.get_or_create(None, "K", None)
    rec = asyncio.run(copilot.run_turn(None, conv, "should we roll back?", mc.hands, _noop, {"operator": "K", "entrance": "copilot"}))
    assert rec["answer"].startswith("I proposed") and rec["trail"][0]["name"] == "propose_action"
    token = rec["trail"][0]["summary"].split()[-1]
    ap = next(a for a in client.get("/api/approvals", headers=AUTH).json() if a["token"] == token)
    assert ap["entrance"] == "copilot" and ap["params"] == {"service": "activation"} and ap["tier"] == 2
    row = next(r for r in client.get("/api/audit?limit=20", headers=AUTH).json() if r["approval_token"] == token)
    assert row["result"] == "pending" and row["entrance"] == "copilot"
    # the model's own approval is impossible twice over: no tool, and the route refuses the entrance
    r = client.post(f"/api/approvals/{token}/approve", headers={**AUTH, "X-Operator": "K", "X-Entrance": "copilot"})
    assert r.status_code == 403
    st = asyncio.run(mc.hands.call("proposal_status", {"token": token}, {"operator": "K", "entrance": "copilot"}))
    assert st["status"].startswith("pending") and st["requested"]["via"] == "copilot"
    # a human can
    assert client.post(f"/api/approvals/{token}/approve", headers=K).json()["status"] == "executed"
    # …and the copilot can now SEE that (CORRECTIONS-DAY23 N8) — the refused copilot attempt is not the decision
    st = asyncio.run(mc.hands.call("proposal_status", {"token": token}, {"operator": "K", "entrance": "copilot"}))
    assert st["status"] == "approved and executed" and st["decided"]["via"] == "button"


def test_a_bad_proposal_is_an_error_the_model_sees(client, monkeypatch):
    out = asyncio.run(mc.propose("rollback", {"service": "fraud-service"}, "x", {"operator": "K", "entrance": "copilot"}))
    assert "error" in out
    out = asyncio.run(mc.propose("drop_database", {}, "x", {"operator": "K", "entrance": "copilot"}))
    assert "not in the catalog" in out["error"]


def test_the_tool_budget_is_eight(client, monkeypatch):
    rounds = [{"stop_reason": "tool_use", "content": [tool_use(i, "firing_alerts", {}), tool_use(i + 100, "firing_alerts", {})]} for i in range(6)]
    rounds.append({"content": [{"type": "text", "text": "Out of budget; here is what I have."}]})
    monkeypatch.setattr(copilot, "_stream_round", script(rounds))
    called = []

    async def fake_alerts(self):
        called.append(1)
        return [{"note": "none"}]
    monkeypatch.setattr(copilot.Hands, "firing_alerts", fake_alerts)
    conv = mc.conversations.get_or_create(None, "K", None)
    rec = asyncio.run(copilot.run_turn(None, conv, "anything wrong?", mc.hands, _noop, {"operator": "K", "entrance": "copilot"}))
    assert len(called) == 8
    assert sum(1 for t in rec["trail"] if "budget exhausted" in t["summary"]) == 4


def test_a_failed_model_call_leaves_no_half_turn(client, monkeypatch):
    async def boom(http, messages, emit):
        raise copilot.ModelError(529, "overloaded")
    monkeypatch.setattr(copilot, "_stream_round", boom)
    conv = mc.conversations.get_or_create(None, "K", None)
    rec = asyncio.run(copilot.run_turn(None, conv, "q", mc.hands, _noop, {"operator": "K", "entrance": "copilot"}))
    assert "529" in rec["note"] and conv["messages"] == []


# ------------------------------------------------------------- the route --
def test_chat_streams_and_the_answer_can_be_graded(client, monkeypatch):
    monkeypatch.setattr(mc.config, "ANTHROPIC_API_KEY", "k")
    monkeypatch.setattr(copilot, "_stream_round", script([
        {"stop_reason": "tool_use", "content": [tool_use(7, "kubectl_get", {"args": "get secret x -n payments"})]},
        {"content": [{"type": "text", "text": "That is off limits (kubectl_get)."}]},
    ]))
    with client.stream("POST", "/api/chat", headers=K, json={"message": "show me the secrets", "incident": "INC-1-abcd"}) as r:
        assert r.status_code == 200
        text = "".join(r.iter_text())
    events = [l[7:] for l in text.splitlines() if l.startswith("event: ")]
    assert events[0] == "conversation" and "tool_call" in events and events[-1] == "done"
    done = json.loads([l for l in text.splitlines() if l.startswith("data: ")][-1][6:])
    assert done["tool_calls"] == 1 and done["cost_usd"] is not None
    row = client.post("/api/eval", headers=K, json={"turn_id": done["turn_id"], "verdict": "up", "comment": "refused correctly"}).json()
    assert row["draft"] == "copilot" and row["incident"] == "INC-1-abcd"
    ev = next(e for e in client.get("/api/eval", headers=AUTH).json() if e["id"] == row["id"])
    assert ev["question"] == "show me the secrets" and ev["trail"][0]["name"] == "kubectl_get"
    tool_row = next(r for r in client.get("/api/audit?limit=50", headers=AUTH).json() if r["action"] == "tool:kubectl_get")
    assert tool_row["tier"] == 0 and tool_row["entrance"] == "copilot" and tool_row["result"] == "error"
    turn = next(t for t in client.get("/api/chat/turns", headers=AUTH).json() if t["id"] == done["turn_id"])
    assert (turn["tool_calls"], turn["tools"], turn["entrance"]) == (1, "kubectl_get", "copilot")


# ------------------------------------------------------------------- MCP --
def rpc(client, method, params=None, i=1, headers=MCP_H):
    return client.post("/mcp", headers=headers, json={"jsonrpc": "2.0", "id": i, "method": method, **({"params": params} if params else {})})


def test_mcp_needs_the_token(client):
    assert client.post("/mcp", json={}).status_code == 401
    assert rpc(client, "tools/list", headers={**MCP_H, "Authorization": "Bearer wrong"}).status_code == 401


def test_mcp_lists_the_same_tools_and_no_approve(client):
    names = [t["name"] for t in rpc(client, "tools/list").json()["result"]["tools"]]
    assert sorted(names) == sorted(t["name"] for t in copilot.TOOLS)


def test_mcp_clients_get_the_platform_facts_not_just_the_tools(client):
    """CORRECTIONS-DAY23 N10: the facts travel with the tools."""
    r = rpc(client, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "t", "version": "0"}})
    ins = r.json()["result"]["instructions"]
    assert "store_id=EGIFT" in ins and "issuer_declined" in ins and "rates, not raw counts" in ins


def test_mcp_calls_are_audited_with_entrance_mcp_and_the_callers_name(client):
    r = rpc(client, "tools/call", {"name": "kubectl_get", "arguments": {"args": "get secret ai-keys -n payments"}})
    assert "off limits" in r.text
    row = client.get("/api/audit?limit=5", headers=AUTH).json()[0]
    assert (row["action"], row["entrance"], row["operator"]) == ("tool:kubectl_get", "mcp", "claude-code")


def test_mcp_can_propose_but_the_proposal_waits_for_a_human(client):
    r = rpc(client, "tools/call", {"name": "propose_action", "arguments": {"action_id": "scale", "params": {"service": "egift", "replicas": 2},
                                                                           "reason": "mcp test"}})
    token = json.loads(r.json()["result"]["content"][0]["text"])["token"]
    ap = next(a for a in client.get("/api/approvals", headers=AUTH).json() if a["token"] == token)
    assert ap["entrance"] == "mcp" and ap["operator"] == "claude-code"
    assert client.post(f"/api/approvals/{token}/approve", headers={**AUTH, "X-Operator": "x", "X-Entrance": "mcp"}).status_code == 403
    client.post(f"/api/approvals/{token}/decline", headers=K)


async def _noop(*_):
    return None


def test_a_feature_the_account_rejects_is_dropped_not_fatal(monkeypatch):
    calls = []

    def handler(req):
        body = json.loads(req.content)
        calls.append(body)
        if "fallbacks" in body:
            return httpx.Response(400, json={"error": {"message": "fallbacks: unknown field (server-side-fallback beta not enabled)"}})
        ok = [{"type": "message_start", "message": {"model": "m", "usage": {}}},
              {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
              {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "fine"}},
              {"type": "content_block_stop", "index": 0}, {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}]
        return httpx.Response(200, text="".join(f"data: {json.dumps(e)}\n\n" for e in ok))
    monkeypatch.setattr(copilot, "FEATURES", {"fallbacks": True, "strict": True, "display": True})
    monkeypatch.setattr(copilot.config, "ANTHROPIC_API_KEY", "k")

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as h:
            conv = {"messages": []}
            return await copilot.run_turn(h, conv, "q", None, _noop, {"operator": "K", "entrance": "copilot"})
    rec = asyncio.run(go())
    assert rec["answer"] == "fine" and copilot.FEATURES["fallbacks"] is False and len(calls) == 2


def test_schema_too_complex_turns_strict_off_instead_of_failing(monkeypatch):
    """The real API's answer on mission-control:59 (CORRECTIONS-DAY23 B2)."""
    calls = []

    def handler(req):
        body = json.loads(req.content)
        calls.append(body)
        if any(t.get("strict") for t in body["tools"]):
            return httpx.Response(400, json={"type": "error", "error": {"type": "invalid_request_error", "message": "Schema is too complex."}})
        ok = [{"type": "message_start", "message": {"model": "m", "usage": {}}},
              {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
              {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "fine"}},
              {"type": "content_block_stop", "index": 0}, {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}]
        return httpx.Response(200, text="".join(f"data: {json.dumps(e)}\n\n" for e in ok))
    monkeypatch.setattr(copilot, "FEATURES", {"fallbacks": True, "strict": True, "display": True})
    monkeypatch.setattr(copilot.config, "ANTHROPIC_API_KEY", "k")

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as h:
            return await copilot.run_turn(h, {"messages": []}, "q", None, _noop, {"operator": "K", "entrance": "copilot"})
    rec = asyncio.run(go())
    assert rec["answer"] == "fine" and copilot.FEATURES["strict"] is False and len(calls) == 2


def test_an_alert_storm_is_grouped_not_truncated(monkeypatch):
    """CORRECTIONS-DAY23 N8: 40 copies of one alert must not push the others out of the result."""
    storm = [{"labels": {"alertname": "PrometheusMissingRuleEvaluations", "severity": "warning"}, "state": "pending",
              "activeAt": f"2026-09-24T15:0{i % 3}:15Z", "annotations": {"summary": "x" * 180}} for i in range(40)]
    real = [{"labels": {"alertname": "ActivationHighErrorRate", "severity": "critical", "service": "activation"},
             "state": "firing", "activeAt": "2026-09-24T14:48:13Z", "annotations": {}},
            {"labels": {"alertname": "Watchdog", "severity": "none"}, "state": "firing", "activeAt": "x", "annotations": {}}]

    def prom(req):
        return httpx.Response(200, json={"status": "success", "data": {"alerts": storm + real}})

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(prom)) as h:
            return await copilot.Hands(h, None).call("firing_alerts", {}, {})
    out = asyncio.run(go())
    names = [g["alertname"] for g in out["groups"]]
    assert out["alerts_total"] == 42 and names[0] == "ActivationHighErrorRate" and names[-1] == "Watchdog"
    storm_row = next(g for g in out["groups"] if g["alertname"] == "PrometheusMissingRuleEvaluations")
    assert storm_row["count"] == 40 and storm_row["since"] == "2026-09-24T15:00:15Z"
    assert len(copilot._truncate(out)) < copilot.MAX_RESULT_CHARS


def test_a_failed_hop_is_named_not_guessed(monkeypatch):
    """CORRECTIONS-DAY23 B3: 'ConnectError: All connection attempts failed' was read as 'Splunk may be down';
    the hop that failed was the incident bot. The tool result now names the hop."""
    monkeypatch.setattr(copilot.config, "BOT_URL", "http://incident-bot.payments:8020")

    def refuse(req):
        raise httpx.ConnectError("All connection attempts failed", request=req)

    async def go():
        async with httpx.AsyncClient(transport=httpx.MockTransport(refuse)) as h:
            return await copilot.Hands(h, None).call("search_logs", {"spl": "app.service=activation"}, {})
    out = asyncio.run(go())
    assert "could not connect to the incident bot" in out["error"] and "says nothing about the systems behind it" in out["error"]
    assert copilot.SEARCH_TIMEOUT_S > 45                      # longer than the bot's own Splunk budget


# ------------------------------------------------------------------- UI guard --
def test_no_effect_returns_a_value():
    """CORRECTIONS-DAY23 B1: `useEffect(() => expr)` returns expr, and React calls a returned value as the
    cleanup. Newer Chrome returns a Promise from scrollIntoView() — the Copilot page went blank. Effects
    here always use a block body."""
    import pathlib
    import re
    src = pathlib.Path(__file__).resolve().parent.parent / "ui" / "src"
    bad = [f"{p.relative_to(src)}:{i}" for p in src.rglob("*.tsx") for i, line in enumerate(p.read_text().splitlines(), 1)
           if re.search(r"use(Layout)?Effect\(\(\)\s*=>\s*[^{\s]", line)]
    assert not bad, f"effects with an expression body (use braces): {bad}"
