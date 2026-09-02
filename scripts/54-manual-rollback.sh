#!/usr/bin/env bash
# Day 6, Step 7 — the manual rollback drill, timed.
# The pipeline will not always be there. Run this AFTER re-deploying the bad build and
# BEFORE Verify finishes (you have ~2 minutes), or after disabling the job's post block.
source "$(dirname "$0")/lib.sh"
require_cluster
SVC="${1:-activation}"

step "Rollout history"
k rollout history "deployment/$SVC" -n "$PAYMENTS_NS"
echo
CUR=$(k get "deployment/$SVC" -n "$PAYMENTS_NS" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
say "  current revision: $CUR"
read -rp "  Roll back to revision (blank = previous): " REV
T0=$(date +%s)
say "  clock started $(date +%T)"

step "Rolling back"
if [[ -n "$REV" ]]; then k rollout undo "deployment/$SVC" -n "$PAYMENTS_NS" --to-revision="$REV"
else k rollout undo "deployment/$SVC" -n "$PAYMENTS_NS"; fi
k rollout status "deployment/$SVC" -n "$PAYMENTS_NS" --timeout=180s
T1=$(date +%s); say "  pods healthy after $((T1-T0))s"

step "Waiting for the error rate to return to baseline (< 5%)"
METRIC=activation_requests_total; [[ "$SVC" == egift ]] && METRIC=egift_orders_total
for _ in $(seq 1 20); do
  E=$(promql "100 * sum(rate(${METRIC}{status=\"error\"}[1m])) / clamp_min(sum(rate(${METRIC}[1m])), 0.001)" | python3 "$LAB_ROOT/tools/promjson.py" value '{:.1f}')
  printf '  t+%-4ss error rate %s%%\n' "$(( $(date +%s) - T0 ))" "$E"
  [[ "$E" != "no data" ]] && python3 -c "import sys; sys.exit(0 if float('$E') < 5 else 1)" && break
  sleep 15
done
T2=$(date +%s)
step "Result"
say "  undo issued -> pods healthy:     $((T1-T0))s"
say "  undo issued -> error rate < 5%:  $((T2-T0))s   <- write this in INC-0006"
dim "On Day 12 you automate this and compare."
k annotate "deployment/$SVC" -n "$PAYMENTS_NS" kubernetes.io/change-cause="MANUAL rollback (drill, $((T2-T0))s to recovery)" --overwrite >/dev/null
