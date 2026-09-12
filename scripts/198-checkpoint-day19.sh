#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 19 exit criteria"

# Warm start, timed and recorded
[[ -f checkpoints/day19-warm-start.txt ]] && grep -qE 'warm start .*: [0-9]+ min' checkpoints/day19-warm-start.txt && t_ok "warm start timed: $(cat checkpoints/day19-warm-start.txt | cut -c1-80)" || t_fail "no checkpoints/day19-warm-start.txt (190)"
grep -qE 'warm start: \*\*[0-9]+ min\*\*|\*\*warm start: [0-9]+ min\*\*' README.md && t_ok "README: the two-number infrastructure story (30 min laptop / N min cloud)" || t_fail "README still says 'warm start: __ min' — write the number"
grep -q 'CW_LOG_GROUP' services/incident-bot/enrich.py && grep -q 'payments/incident-bot' infra/aws/eks/pod-identity.tf && t_ok "the third collector on EKS: CloudWatch via Pod Identity (enrich.py + pod-identity.tf)" || t_fail "CloudWatch collector not wired"
(cd services/incident-bot && python3 -m pytest -q tests/test_cw.py >/dev/null 2>&1) && t_ok "SPL -> Insights translator tests pass" || t_fail "tests/test_cw.py failing"
ls reports/daily/*-eks-warm.md >/dev/null 2>&1 && t_ok "the first brief against the fresh environment ($(ls reports/daily/*-eks-warm.md | head -1))" || t_fail "no <date>-eks-warm report (190 phase 8)"

# The game day
[[ -f gameday/.run-2.t0 ]] && t_ok "game day 2 started at $(cat gameday/.run-2.t0)" || t_fail "game day 2 never started (192 start)"
[[ -f gameday/.scenario-2.log ]] && (( $(grep -c 'injected' gameday/.scenario-2.log) == 3 )) && t_ok "three faults injected (scenario log)" || t_fail "scenario log does not show three injections"
N=$(grep -c '^- ' gameday/timeline-2.md 2>/dev/null || echo 0); (( N >= 10 )) && t_ok "timeline-2: $N entries" || t_fail "gameday/timeline-2.md has $N entries (need 10+)"
for n in 0020 0021 0022; do [[ -f incidents/INC-$n.md ]] && ! grep -q '_fill in_' incidents/INC-$n.md && t_ok "incidents/INC-$n.md written" || t_fail "incidents/INC-$n.md missing or still a scaffold"; done
grep -qE '^\| 0020 \|' docs/ops-kpis.md && grep -qE '^\| 0021 \|' docs/ops-kpis.md && grep -qE '^\| 0022 \|' docs/ops-kpis.md && t_ok "ops-kpis rows 0020–0022 (the dataset closed)" || t_fail "docs/ops-kpis.md rows 0020/0021/0022"
[[ -f gameday/retro-2.md ]] && ! grep -q '^_…_' gameday/retro-2.md && grep -q 'graduation' gameday/retro-2.md && t_ok "gameday/retro-2.md written, graduation questions answered" || t_fail "gameday/retro-2.md missing or unanswered"
ls reports/daily/*-eks-closing.md >/dev/null 2>&1 && t_ok "the closing brief ($(ls reports/daily/*-eks-closing.md | head -1))" || t_fail "no <date>-eks-closing report (192 report)"
grep -q 'Eval 10' docs/ai-eval.md && ! grep -qE '^\| alert that opened it \| _' docs/ai-eval.md && t_ok "ai-eval Eval 10 graded" || t_fail "docs/ai-eval.md Eval 10 not graded"
grep -qE '^\| 1 \| [^_].{10,}\| ' docs/eks-notes.md && grep -qc 'Papercuts' docs/eks-notes.md >/dev/null && t_ok "eks-notes: papercuts recorded" || t_fail "docs/eks-notes.md papercuts table still the template"

# Destroyed, verified, recorded
if [[ -f checkpoints/day16-torn-down.txt ]] && [[ "$(stat -c %Y checkpoints/day16-torn-down.txt)" -gt "$(stat -c %Y gameday/.run-2.t0 2>/dev/null || echo 0)" ]]; then
  t_ok "teardown ran after the game ($(cat checkpoints/day16-torn-down.txt))"
  if aws sts get-caller-identity >/dev/null 2>&1; then
    ./scripts/155-aws-verify-destroyed.sh >/dev/null 2>&1 && t_ok "155: nothing billing anywhere (visual pass done by a script)" || t_fail "155 lists leftovers"
  else warn "no AWS session — aws sso login --profile lab, then re-run for the 155 sweep"; fi
else t_fail "not torn down after the game (./scripts/167-eks-teardown.sh --all)"; fi
grep -qE '^\| 19[^|]*\|[^|]*\|[^|]*\| *\$[0-9]' docs/aws-costs.md && t_ok "docs/aws-costs.md row 19 has a cost" || warn "aws-costs row 19: tomorrow's 154 --row 19 (and the week's total)"
git status --porcelain 2>/dev/null | grep -c . >/dev/null && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 19 done." || { warn "Not done yet."; exit 1; }
