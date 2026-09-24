"""
mcp_server.py — Day 23 Step 4: the copilot's tool surface, published as an MCP server on /mcp.

One tool surface, two AI clients, one policy. Claude Code, Cursor or Claude Desktop reach the same
ten tools the in-browser copilot uses — the same allow-lists (copilot.check_kubectl), the same
truncation, the same audit rows (entrance: mcp) — and the same single write: propose_action, which
queues a tier-2 approval a HUMAN grants in the browser. There is no approve tool, and the approval
routes refuse the mcp entrance anyway (app.py HUMAN_ENTRANCES): two fences, again.

Auth: the same bearer token as /api/*, checked in MCPGate before a byte reaches the MCP app. The
operator for the audit row is the X-Operator header the client is configured to send (docs/mcp.md),
or "mcp-client" when it sends none.
"""

import json

from mcp.server.mcpserver import Context, MCPServer
from mcp.server.transport_security import TransportSecuritySettings

import copilot

INSTRUCTIONS = ("Read-only tools over a payments platform (Prometheus, Splunk via the incident bot, incident records, "
                "the knowledge base, read-only kubectl) plus propose_action, which only QUEUES an action for a human "
                "to approve in Mission Control. Nothing you call can change the platform. Cite what the tools return.")


def _desc(name: str) -> str:
    return next(t["description"] for t in copilot.TOOLS if t["name"] == name)


def build(get_hands):
    """get_hands() -> the app's AuditedHands (created in the app's lifespan, after the HTTP client)."""
    mcp = MCPServer("bhn-sim mission control", instructions=INSTRUCTIONS)

    def ctx_of(ctx: Context) -> dict:
        op = ""
        try:
            op = (ctx.headers or {}).get("x-operator", "") if hasattr(ctx, "headers") else ""
        except Exception:  # noqa: BLE001
            op = ""
        op = "".join(ch for ch in str(op) if ch.isalnum() or ch in "._@ -")[:60] or "mcp-client"
        return {"operator": op, "entrance": "mcp"}

    async def run(name: str, args: dict, ctx: Context) -> str:
        out = await get_hands().call(name, args, ctx_of(ctx))
        return copilot._truncate(out)

    @mcp.tool(description=_desc("search_kb"), structured_output=False)
    async def search_kb(symptoms: str, ctx: Context) -> str:
        return await run("search_kb", {"symptoms": symptoms}, ctx)

    @mcp.tool(description=_desc("query_prometheus"), structured_output=False)
    async def query_prometheus(query: str, ctx: Context) -> str:
        return await run("query_prometheus", {"query": query}, ctx)

    @mcp.tool(description=_desc("firing_alerts"), structured_output=False)
    async def firing_alerts(ctx: Context) -> str:
        return await run("firing_alerts", {}, ctx)

    @mcp.tool(description=_desc("search_logs"), structured_output=False)
    async def search_logs(spl: str, ctx: Context, earliest: str = "-30m") -> str:
        return await run("search_logs", {"spl": spl, "earliest": earliest}, ctx)

    @mcp.tool(description=_desc("recent_deploys"), structured_output=False)
    async def recent_deploys(service: str, ctx: Context) -> str:
        return await run("recent_deploys", {"service": service}, ctx)

    @mcp.tool(description=_desc("kubectl_get"), structured_output=False)
    async def kubectl_get(args: str, ctx: Context) -> str:
        return await run("kubectl_get", {"args": args}, ctx)

    @mcp.tool(description=_desc("get_incidents"), structured_output=False)
    async def get_incidents(ctx: Context, status: str = "any") -> str:
        return await run("get_incidents", {"status": status}, ctx)

    @mcp.tool(description=_desc("get_incident"), structured_output=False)
    async def get_incident(incident_id: str, ctx: Context) -> str:
        return await run("get_incident", {"incident_id": incident_id}, ctx)

    @mcp.tool(description=_desc("proposal_status"), structured_output=False)
    async def proposal_status(token: str, ctx: Context) -> str:
        return await run("proposal_status", {"token": token}, ctx)

    @mcp.tool(description=_desc("propose_action"), structured_output=False)
    async def propose_action(action_id: str, reason: str, ctx: Context, params: dict | None = None) -> str:
        return await run("propose_action", {"action_id": action_id, "params": params or {}, "reason": reason}, ctx)

    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,          # a web page cannot drive it through your browser
        allowed_hosts=["localhost:*", "127.0.0.1:*", "mission-control.payments:*", "mission-control:*", "testserver"],
        allowed_origins=["http://localhost:*", "http://127.0.0.1:*"])
    asgi = mcp.streamable_http_app(streamable_http_path="/mcp", transport_security=security, stateless_http=True,
                                   json_response=True)
    return mcp, asgi


class MCPGate:
    """ASGI middleware: /mcp goes to the MCP app — after the bearer check — everything else to FastAPI."""

    def __init__(self, app, get_mcp_app, token_ok):
        self.app, self.get_mcp_app, self.token_ok = app, get_mcp_app, token_ok

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and (scope["path"] == "/mcp" or scope["path"].startswith("/mcp/")):
            auth = dict(scope.get("headers") or []).get(b"authorization", b"").decode(errors="replace")
            if not (auth.startswith("Bearer ") and self.token_ok(auth[7:])):
                body = json.dumps({"detail": "missing or wrong bearer token"}).encode()
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"), (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": body})
                return
            mcp_app = self.get_mcp_app()
            if mcp_app is None:                        # before startup finished
                await send({"type": "http.response.start", "status": 503, "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"starting"})
                return
            return await mcp_app(scope, receive, send)
        return await self.app(scope, receive, send)
