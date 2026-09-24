#!/usr/bin/env bash
# Day 23 — Claude Code's headersHelper for the bhn-sim MCP server (.mcp.json).
# Claude Code runs this from the repo root at connect time (and again on a 401) and sends what it
# prints as HTTP headers. The bearer token is read from ~/.bhn-sim/mc-token at that moment, so it is
# never written into .mcp.json, ~/.claude.json or an environment variable — and never printed to a
# terminal: stdout goes to Claude Code, not to you. X-Operator is who the audit rows name.
set -euo pipefail
[[ -t 1 ]] && { echo "this prints the bearer token for Claude Code (.mcp.json) — do not run it by hand" >&2; exit 2; }
TOKF="$HOME/.bhn-sim/mc-token"
[[ -s "$TOKF" ]] || { echo "no $TOKF — ./scripts/210-mc-config.sh" >&2; exit 1; }
OP="${MC_OPERATOR:-${USER:-someone}} via claude-code"
python3 - "$TOKF" "$OP" <<'PY'
import json, sys
tok = open(sys.argv[1]).read().strip()
print(json.dumps({"Authorization": f"Bearer {tok}", "X-Operator": sys.argv[2]}))
PY
