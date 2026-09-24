#!/usr/bin/env bash
# Day 23 exit criteria — the copilot, the palette, the MCP server, the eval table.
# Like 228, the browser work is proven by what it leaves behind: turns, approvals and audit rows,
# each with the entrance it came through.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18040; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }; trap cleanup EXIT
mc(){ curl -s -m 10 -H "Authorization: Bearer $(cat "$TOKF")" -H "X-Operator: checkpoint" -H "X-Entrance: api" "$@"; }
py(){ python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }

step "The image — the copilot configured"
IMG=$(k get deploy mission-control -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ "$IMG" =~ ^mission-control:[0-9]+$ ]] && t_ok "deployed by the pipeline: $IMG" || t_fail "mission-control not deployed by Jenkins (image: ${IMG:-none})"
[[ -s "$TOKF" ]] || { t_fail "no ~/.bhn-sim/mc-token — ./scripts/210-mc-config.sh"; step "Score"; say "passed: $PASS   failed: $FAIL"; exit 1; }
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
B="http://localhost:$PORT"
CFG=$(mc "$B/api/config" || true)
echo "$CFG" | py 'import sys; c=d["copilot"]; print(c["model"]); sys.exit(0 if c["enabled"] else 1)' >/tmp/mc-model.$$ \
  && t_ok "copilot enabled: $(cat /tmp/mc-model.$$), key from secret/ai-keys" || t_fail "copilot not enabled — this image predates Day 23, or ai-keys has no ANTHROPIC_API_KEY (90-ai-secret.sh --check)"
rm -f /tmp/mc-model.$$
k exec -n "$PAYMENTS_NS" deploy/mission-control -- sh -c 'test -z "$AI_MODEL$AI_BASE_URL"' 2>/dev/null \
  && t_ok "only the one key from ai-keys reached the pod (not the bot's whole secret)" || t_fail "mission-control has the bot's AI_* env — k8s/mission-control.yaml should take ANTHROPIC_API_KEY only"

step "Step 1-2 — the warm-up from the browser, with its tool trails"
TURNS=$(mc "$B/api/chat/turns?limit=500" || echo '[]')
WARM=$(grep -v '^#' docs/copilot-questions/warmup.txt | sed '/^\s*$/d')
N=$(echo "$TURNS" | WARM="$WARM" py '
import os
qs = [q.strip().lower() for q in os.environ["WARM"].splitlines()]
got = {q for q in qs for t in d if t["entrance"] == "copilot" and t["question"].strip().lower().endswith(q) and (t["tool_calls"] or 0) > 0}
print(len(got))' || echo 0)
(( N == 5 )) && t_ok "all 5 warm-up questions asked from the browser, each answered with a tool trail" || t_fail "warm-up: $N of 5 asked from the Copilot page with at least one tool call (DAY23 step 6)"
TOOLS=$(echo "$TURNS" | py 'print(" ".join(sorted({x for t in d if t["entrance"]=="copilot" for x in (t["tools"] or "").split(",") if x})))' || true)
say "  tools the copilot chose so far: ${TOOLS:-none}"

step "propose_action — the AI asks, a human grants"
AUD=$(mc "$B/api/audit?limit=2000" || echo '[]')
echo "$AUD" | py '
import sys
prop = {r["approval_token"] for r in d if r["entrance"] == "copilot" and r["result"] == "pending" and r["approval_token"]}
ok = [r for r in d if r["approval_token"] in prop and r["result"] == "ok" and r["entrance"] in ("button", "command")]
r = ok[0] if ok else {}
print(r.get("action", ""), r.get("approval_token", ""), "approved by", r.get("operator", "")); sys.exit(0 if ok else 1)' >/tmp/mc-p.$$ \
  && t_ok "a copilot proposal (entrance: copilot) executed after a human's Approve: $(cat /tmp/mc-p.$$)" \
  || t_fail "no copilot proposal granted from the banner yet (DAY23 step 7)"
rm -f /tmp/mc-p.$$
echo "$AUD" | py 'import sys; sys.exit(1 if any(r["tier"]==2 and r["result"]=="ok" and r["entrance"] in ("copilot","mcp") for r in d) else 0)' \
  && t_ok "no tier-2 action ever executed through the copilot or mcp entrance" || t_fail "a tier-2 action executed with entrance copilot/mcp — that is a bypass"

step "Step 3 — the palette is the third entrance"
C=$(echo "$AUD" | py 'print(sum(1 for r in d if r["entrance"]=="command"))' || echo 0)
(( C > 0 )) && t_ok "$C audit row(s) with entrance: command (Ctrl+K)" || t_fail "no palette actions yet — Ctrl+K, /report or /note (DAY23 step 8)"

step "Step 4 — Claude Code through /mcp, audited"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST "$B/mcp" -H 'Content-Type: application/json' -d '{}')
[[ "$CODE" == 401 ]] && t_ok "/mcp refuses a request without the token (401)" || t_fail "/mcp without the token: HTTP $CODE"
for T in search_kb query_prometheus; do
  W=$(echo "$AUD" | py "r=[r for r in d if r['action']=='tool:$T' and r['entrance']=='mcp' and 'claude-code' in r['operator']]; print(r[0]['operator'] if r else '')" || true)
  [[ -n "$W" ]] && t_ok "tool:$T called through MCP by '$W' (entrance: mcp)" || t_fail "no tool:$T row from Claude Code (entrance mcp, operator … via claude-code) — docs/mcp.md"
done

step "Step 2/5 — every answer gradeable, the eval page has the rows"
EV=$(mc "$B/api/eval" || echo '[]')
G=$(echo "$EV" | py 'print(sum(1 for r in d if r["draft"]=="copilot"))' || echo 0)
(( G >= 5 )) && t_ok "$G copilot answers graded (Evals page)" || t_fail "$G copilot answers graded — want the 5 warm-up + the adversarial ones"
echo "$TURNS" | py 'import sys; sys.exit(0 if any("approve the pending" in t["question"].lower() for t in d) else 1)' \
  && t_ok "adversarial: \"approve the pending rollback\" was asked" || t_fail "adversarial-day23.txt not asked from the browser yet (DAY23 step 10)"
grep -q "^## Eval 13" docs/ai-eval.md && t_ok "docs/ai-eval.md Eval 13 (the MCP half hour and the summary)" || t_fail "no '## Eval 13' in docs/ai-eval.md"

step "The ship"
set +e; ./infra/local/tf.sh plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1; RC=$?; set -e
(( RC == 0 )) && t_ok "terraform plan clean" || t_fail "terraform plan exit $RC — ./infra/local/tf.sh plan"
[[ -f CORRECTIONS-DAY23.md ]] && t_ok "CORRECTIONS-DAY23.md ($(grep -c '^### ' CORRECTIONS-DAY23.md) entries)" || t_fail "no CORRECTIONS-DAY23.md"
[[ -z "$(git status --porcelain)" ]] && t_ok "working tree clean" || t_fail "uncommitted changes"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 23 done. The AI proposes; a human decides — through any door." || { warn "Not done yet."; exit 1; }
