#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 14 exit criteria"

# Part A — the numbers
for n in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0012 0013 0014 0015 0016 0017; do
  grep -qE "^\| $n \|" docs/ops-kpis.md || t_fail "docs/ops-kpis.md has no row $n"
done
[[ $(grep -cE '^\| 00(0[1-9]|1[0-7]) \| [0-9]+ \|' docs/ops-kpis.md) -ge 17 ]] && t_ok "week-over-week table covers all seventeen incidents" || t_fail "week-over-week table incomplete (expected 17 rows with a Day column)"
grep -qE '^\| 001[67] \| 14 \| .*_after the game_' docs/ops-kpis.md && t_fail "rows 0016/0017 still say 'after the game'" || t_ok "game-day rows filled"
grep -q 'week-over-week story' docs/ops-kpis.md && grep -qE '^> \*\*Detection\.\*\*' docs/ops-kpis.md && t_ok "trend paragraph written" || t_fail "trend paragraph missing"

# Part A — the runbook audit
if ./scripts/141-readme-audit.sh --quiet >/dev/null 2>&1; then t_ok "README audit passes (141)"; else t_fail "README audit fails — ./scripts/141-readme-audit.sh"; fi
[[ $(git log --format=%s -- README.md | grep -ci 'audit') -gt 0 ]] && t_ok "README audit committed" || t_fail "no commit mentioning the README audit"   # grep -c, not -q (N7)

# Part B — the game day
[[ -x gameday/scenario-1.sh && -x gameday/note.sh ]] && t_ok "gameday/scenario-1.sh + note.sh" || t_fail "gameday scripts missing"
[[ -f gameday/.run-1.t0 ]] && t_ok "game day 1 ran (T0 $(cat gameday/.run-1.t0))" || t_fail "game day 1 never started — ./scripts/142-gameday.sh start"
n=$(grep -c '^- `' gameday/timeline-1.md 2>/dev/null || echo 0); (( n >= 8 )) && t_ok "timeline: $n scribe entries" || t_fail "timeline has $n entries (a real bridge needs more)"
if [[ -f gameday/.run-1.t0 ]]; then
  T0=$(cat gameday/.run-1.t0)
  cnt=$(bot_get '/incidents' | python3 -c 'import json,sys; t0=sys.argv[1]; d=[i for i in json.load(sys.stdin) if (i.get("opened_at_iso") or "")>=t0]; print("%d %d %s" % (len(d), sum(1 for i in d if i["status"]=="resolved"), ",".join(sorted(set(i.get("service") or "" for i in d)))))' "$T0" 2>/dev/null || echo "0 0 -")
  read -r total resolved svcs <<<"$cnt"
  (( total >= 2 )) && [[ "$svcs" == *egift* && "$svcs" == *settlement* ]] && t_ok "both faults became tickets ($svcs)" || t_fail "tickets since T0: $total ($svcs) — expected egift AND settlement"
  (( total > 0 && resolved == total )) && t_ok "every game-day ticket resolved" || t_fail "$resolved of $total game-day tickets resolved"
fi
EG=$(k get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EMAIL_FAIL_RATE")].value}' 2>/dev/null); SM=$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_FAIL_MODE")].value}' 2>/dev/null)
[[ "${EG:-0.01}" == "0.01" && "${SM:-none}" == "none" ]] && t_ok "both faults reverted (knobs at baseline)" || t_fail "a fault is still live: egift EMAIL_FAIL_RATE=$EG settlement SETTLEMENT_FAIL_MODE=$SM"
[[ -s gameday/retro-1.md ]] && ! grep -q '_fill in_\|^-  *$' gameday/retro-1.md && grep -q 'mislead' gameday/retro-1.md && t_ok "gameday/retro-1.md written" || t_fail "gameday/retro-1.md incomplete"
for f in incidents/INC-0016.md incidents/INC-0017.md; do [[ -s $f ]] && ! grep -q '_fill in_' "$f" && t_ok "$f written" || t_fail "$f incomplete"; done
grep -q 'Eval 6' docs/ai-eval.md 2>/dev/null && t_ok "Eval 6 (game-day hypothesis + copilot) graded in docs/ai-eval.md" || t_fail "docs/ai-eval.md has no Eval 6"

# Part C — week 3
[[ -s docs/aws-costs.md ]] && grep -q 'Budget alarm' docs/aws-costs.md && t_ok "docs/aws-costs.md (rules + table)" || t_fail "docs/aws-costs.md missing"
grep -q 'Week 3' README.md && t_ok "README has the week-3 plan" || t_fail "README lacks the week-3 plan"

git status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 14 done. Week 2 closed." || { warn "Not done yet."; exit 1; }
