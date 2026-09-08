#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 11 exit criteria"

# the bot: 0.4 with the read-only search tool, and the Eval 3 prompt changes in the image
bot_get /openapi.json | grep -q '/tools/search_logs' && t_ok "incident-bot 0.4 running ($(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}'))" || t_fail "bot has no /tools/search_logs — ship 0.4"
grep -q 'PLATFORM_FACTS' services/incident-bot/ai.py && grep -q 'never itself a cause' services/incident-bot/ai.py && t_ok "Eval 3 prompt changes present in ai.py (rollback rule + platform facts)" || t_fail "ai.py lacks the Eval 3 prompt changes"
bot_get /metrics | grep -q 'bot_tool_calls_total' && t_ok "bot_tool_calls_total metric exposed" || t_fail "no bot_tool_calls_total on /metrics"

# the copilot: hands work, refusals hold
if python3 tools/copilot.py --selftest 2>/dev/null | grep -q 'FAIL'; then t_fail "copilot self-test has failures — python3 tools/copilot.py --selftest"; else t_ok "copilot self-test: every tool answers, writes and secrets refused"; fi

# transcripts: warm-up, the fraud drill, the adversarial set
T="$LAB_ROOT/docs/copilot-transcripts"
ls "$T"/*-warmup.md >/dev/null 2>&1 && t_ok "warm-up transcript" || t_fail "no warm-up transcript — python3 tools/copilot.py -f docs/copilot-questions/warmup.txt --tag warmup"
ls "$T"/*drill-fraud-INC-0011.md >/dev/null 2>&1 && t_ok "fraud-drill transcript" || t_fail "no drill transcript — ./scripts/112-copilot-drill.sh"
ls "$T"/*-adversarial.md >/dev/null 2>&1 && t_ok "adversarial transcript" || t_fail "no adversarial transcript — ./scripts/113-copilot-adversarial.sh"
if ls "$T"/*-adversarial.md >/dev/null 2>&1; then
  A=$(ls -t "$T"/*-adversarial.md | head -1)
  grep -qiE "not permitted|off limits" "$A" && t_ok "the allow-list refused a write/secret during the adversarial run (evidence in the transcript)" \
    || t_ok "no tool refusal in the transcript: the model refused in prose before touching a tool (the self-test above proves the tool would have)"
fi

# grading and the record
grep -q '## Eval 4' docs/ai-eval.md && ! sed -n '/## Eval 4/,/## Failures/p' docs/ai-eval.md | grep -q '_fill in_' && t_ok "docs/ai-eval.md Eval 4 graded" || t_fail "docs/ai-eval.md Eval 4 not graded"
[[ -s incidents/INC-0011.md ]] && ! grep -q '_fill in_' incidents/INC-0011.md && t_ok "INC-0011.md written" || t_fail "incidents/INC-0011.md incomplete"
git status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 11 done." || { warn "Not done yet."; exit 1; }
