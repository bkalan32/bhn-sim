# The MCP server — Mission Control's tools for any AI client

Day 23 Step 4. `POST /mcp` on mission control (`services/mission-control/mcp_server.py`) publishes
the copilot's tool set over the Model Context Protocol (streamable HTTP, stateless, JSON
responses). Claude Code in your WSL terminal — or Cursor, or Claude Desktop — can then query
Prometheus, search Splunk, read incidents and search the KB **through mission control**, with the
same allow-lists, the same truncation and the same audit log as the in-browser copilot.

**One tool surface, two AI clients, one policy.** That is the shape "engineering assistants"
take in real companies now: the platform team publishes tools, every AI surface consumes them,
and the policy lives with the tools — not in each client's prompt.

## The tools

The same ten the Copilot page uses (`copilot.TOOLS` — the descriptions are shared, so the two
clients cannot drift apart):

| Tool | What it reaches | The fence |
|---|---|---|
| `query_prometheus` | Prometheus instant query | read-only API; result truncated to 6,000 chars |
| `firing_alerts` | Alertmanager's view of Prometheus alerts | read-only |
| `search_logs` | Splunk, through the incident bot's `/tools/search_logs` | the bot's SPL guard (search only, time-bounded) |
| `recent_deploys` | Grafana deploy annotations | read-only, one service |
| `kubectl_get` | kubectl in the mission-control pod | get/describe/logs/explain/rollout status\|history; **no** secrets, configmaps or service accounts; platform namespaces only; no `-A`; logs capped at 80 lines |
| `get_incidents`, `get_incident` | the incident bot's records | read-only |
| `search_kb` | the KB ConfigMap (`kb/*.md`) | read-only |
| `proposal_status` | mission control's audit log | read-only: pending / approved (by whom, via which door) / declined / expired |
| `propose_action` | the action catalog | **queues** a tier-2 approval — it never executes, whatever the action's tier |

There is no approve tool and no execute tool. Even if there were, the approval routes refuse
the `mcp` entrance (`HUMAN_ENTRANCES` in `app.py`): two fences.

## Auth and audit

The same bearer token as `/api/*`, checked by `MCPGate` before a byte reaches the MCP app — no
token, 401. Every tool call writes an audit row: action `tool:<name>`, tier 0, **entrance `mcp`**,
operator from the `X-Operator` header (`mcp-client` if a client sends none). A `propose_action`
lands in the pending banner as "asked by *you via claude-code* via mcp", and waits for a human.

Two more guards the SDK gives for free, both on: **DNS-rebinding protection** (the `Host` must
be localhost / 127.0.0.1 / the in-cluster name; a web page you visit cannot aim your browser at
`localhost:8040/mcp`), and an `Origin` allow-list of localhost only.

## Claude Code — the setup is already in the repo

`.mcp.json` (repo root) declares the server:

```json
{ "mcpServers": { "bhn-sim": { "type": "http", "url": "http://localhost:8040/mcp",
                               "headersHelper": "scripts/mc-mcp-headers.sh" } } }
```

`headersHelper` is a command Claude Code runs from the repo root at connect time (and again on a
401); what it prints are the request headers. `scripts/mc-mcp-headers.sh` reads the token from
`~/.bhn-sim/mc-token` at that moment, so the token is **never** written into `.mcp.json`,
`~/.claude.json` or an environment variable. (It refuses to run on a terminal: its output *is*
the token.) `X-Operator` is `$MC_OPERATOR via claude-code` — `$USER` if you have not set it.

1. `./scripts/220-mc-open.sh` — the port-forward to :8040 (keep it running).
2. `./scripts/230-mcp.sh` — 401 without the token, ten tools with it, and what Claude Code sees.
3. `export MC_OPERATOR=bkalan32` (so the audit rows name you), then `cd ~/bhn-sim && claude`.
   First time in this folder: accept the workspace-trust dialog, then **approve** the project
   server `bhn-sim`. `/mcp` should show it ✔ connected with 10 tools.
4. Ask: **"which store had the most activation errors in the last 30 minutes?"** Claude Code
   will ask permission for each `mcp__bhn-sim__…` tool the first time; allow them.
5. Watch the Audit page (or `python3 tools/mc.py audit 10`): `tool:query_prometheus` (or
   `tool:search_logs`) rows, entrance **mcp**, operator **bkalan32 via claude-code**.
6. Then ask it to search the KB ("what does the KB say about fraud timeouts?") — the
   checkpoint wants both `tool:search_kb` and `tool:query_prometheus` from the `mcp` entrance.

Not installed? `curl -fsSL https://claude.ai/install.sh | bash` in WSL, then `claude` once to sign in.

## Other clients

Anything that speaks streamable HTTP MCP works the same: URL `http://localhost:8040/mcp`,
headers `Authorization: Bearer <token>` and `X-Operator: <you> via <client>`. Clients without a
headers helper keep the token in their own config file — a second copy of a credential; prefer
one that can run a helper.

## Why stateless

`stateless_http=True`, `json_response=True`: every POST is complete on its own — no session id
to lose when the pod restarts or the port-forward reconnects mid-drill, and nothing for one
client to hijack from another. The cost is no server-initiated messages (progress, sampling),
which none of these tools need.
