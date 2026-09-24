#!/usr/bin/env bash
# Day 23 Step 4 — is the MCP endpoint ready for Claude Code? Run it after ./scripts/220-mc-open.sh.
#
#   ./scripts/230-mcp.sh     /mcp refuses without the token, lists the ten tools with it,
#                            and shows whether Claude Code sees the bhn-sim server (.mcp.json)
#
# It lists tools only — tools/list is not audited — so the "entrance: mcp" rows the checkpoint
# looks for can only come from Claude Code itself (docs/mcp.md).
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
TOKF="$HOME/.bhn-sim/mc-token"; B="http://localhost:${MC_PORT:-8040}"
[[ -s "$TOKF" ]] || die "no $TOKF — ./scripts/210-mc-config.sh"
curl -s -m 3 -o /dev/null "$B/healthz" || die "nothing on $B — ./scripts/220-mc-open.sh first"
rpc(){ curl -s -m 10 -X POST "$B/mcp" -H "Accept: application/json, text/event-stream" -H "Content-Type: application/json" \
         -H "mcp-protocol-version: 2025-06-18" -H "X-Operator: 230-mcp-check" "$@" \
         -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'; }

step "The door is locked"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "$B/mcp" -H "Content-Type: application/json" -d '{}')
[[ "$CODE" == 401 ]] && ok "/mcp without the token: 401" || die "/mcp without the token: HTTP $CODE (want 401) — is this image Day 23's?"

step "…and the key opens it"
# set -e would end the script silently on a curl failure (CORRECTIONS-DAY23 N9): say what failed instead.
OUT=$(rpc -H "Authorization: Bearer $(cat "$TOKF")" -w '\n%{http_code}' 2>&1) || die "tools/list: curl failed ($?) — is the port-forward reconnecting after a deploy? ./scripts/220-mc-open.sh --status"
CODE=$(echo "$OUT" | tail -1); OUT=$(echo "$OUT" | sed '$d')
[[ "$CODE" == 200 ]] || die "tools/list: HTTP $CODE — $(echo "$OUT" | head -c 300)"
echo "$OUT" | python3 -c '
import json, sys
try:
    tools = [t["name"] for t in json.load(sys.stdin)["result"]["tools"]]
except Exception:
    sys.exit("  ✗ tools/list did not answer JSON-RPC")
print(f"  ✓ {len(tools)} tools: " + ", ".join(sorted(tools)))
need = {"search_kb", "query_prometheus", "propose_action"}
missing = need - set(tools)
if missing: sys.exit(f"  ✗ missing: {sorted(missing)}")
if any("approve" in t or "set_fault" in t for t in tools): sys.exit("  ✗ an approve/execute tool is exposed — that is a bypass")
print("  ✓ no approve tool, no execute tool: propose_action only queues")
' || die "tools/list failed"

step "Claude Code"
if command -v claude >/dev/null 2>&1; then
  ok "claude $(claude --version 2>/dev/null | head -1)"
  say "  .mcp.json in the repo root declares the server; scripts/mc-mcp-headers.sh supplies the headers."
  claude mcp get bhn-sim 2>&1 | sed 's/^/  /' | head -12 || true
  say "  If it says it needs approval: run \`claude\` in $LAB_ROOT, accept the trust dialog, approve bhn-sim, then /mcp."
else
  warn "claude not found — install Claude Code in WSL: curl -fsSL https://claude.ai/install.sh | bash"
fi
