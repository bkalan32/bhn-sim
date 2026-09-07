#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 9 exit criteria"

IMG=$(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "$IMG" && "$IMG" != "incident-bot:0.1" ]] && t_ok "incident-bot is $IMG (has ai.py)" || t_fail "incident-bot still 0.1"
bot_get /ai | grep -q '"enabled": *true' && t_ok "AI provider configured ($(bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["provider"], d["model"])'))" || t_fail "no AI provider — ./scripts/90-ai-secret.sh"

# a real drill produced both drafts, with notes, from a real model
DRILL=$(bot_get '/incidents?status=resolved' | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(" ".join(i["id"] for i in d if i.get("service")=="activation"))' 2>/dev/null || true)
HIT=""
for id in $DRILL; do
  if bot_get "/incidents/$id" | python3 -c 'import json,sys
d=json.load(sys.stdin)
ok = d.get("ai_meta",{}).get("open",{}).get("ok") and d.get("ai_meta",{}).get("resolved",{}).get("ok")
notes = any(e.get("event")=="note" for e in d.get("timeline",[]))
real = d.get("ai_meta",{}).get("open",{}).get("provider") in ("anthropic","ollama")
sys.exit(0 if (ok and notes and real) else 1)' 2>/dev/null; then HIT="$id"; break; fi
done
[[ -n "$HIT" ]] && t_ok "drill record with both AI drafts AND responder notes ($HIT)" || t_fail "no resolved activation incident with both drafts + notes — ./scripts/92-ai-drill.sh"

[[ -s "$LAB_ROOT/incidents/INC-0008-ai-drafts.md" ]] && t_ok "incidents/INC-0008-ai-drafts.md written by the drill" || t_fail "INC-0008-ai-drafts.md missing"
[[ -s "$LAB_ROOT/incidents/INC-0008.md" ]] && t_ok "incidents/INC-0008.md exists" || t_fail "incidents/INC-0008.md missing"
if [[ -s "$LAB_ROOT/docs/ai-eval.md" ]] && grep -qE 'INC-[0-9]{10}-[0-9a-f]{4}' "$LAB_ROOT/docs/ai-eval.md" && ! grep -q '_fill in_' "$LAB_ROOT/docs/ai-eval.md"; then
  t_ok "docs/ai-eval.md has a graded evaluation (record ID present, no blanks)"
else
  t_fail "docs/ai-eval.md not graded yet (needs the record ID and no '_fill in_' left)"
fi

# resilience: the record says why when the AI is off (proved by 93, evidenced by metrics)
V=$( [[ -s "$LAB_ROOT/checkpoints/day9-resilience.txt" ]] && echo proven || echo "no data")
[[ "$V" != "no data" && "$V" != "0" ]] && t_ok "no-AI path exercised ($(cat "$LAB_ROOT/checkpoints/day9-resilience.txt" 2>/dev/null | cut -c1-20))" || t_fail "run ./scripts/93-ai-resilience.sh"

# settlement 0.3
SIMG=$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)
grep -q 'pushadd_to_gateway' "$LAB_ROOT/services/settlement/settle.py" && t_ok "settle.py: failed runs no longer erase last_success" || t_fail "settle.py still uses push_to_gateway"
[[ "$SIMG" != "settlement:0.1" && "$SIMG" != "settlement:0.2" && -n "$SIMG" ]] && t_ok "settlement image is $SIMG (0.3 shipped)" || t_fail "settlement 0.3 not deployed ($SIMG)"

git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 9 complete. Day 10: the bot enriches incidents with metrics, deploys and log reasons, then drafts a diagnosis." || die "Not done yet."
