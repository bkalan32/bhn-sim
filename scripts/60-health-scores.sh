#!/usr/bin/env bash
# Day 7, Part B — load the health-score rules and read them back.
source "$(dirname "$0")/lib.sh"
require_cluster
step "Applying k8s/alerts.yaml (now with the health-scores group)"
k apply -f "$LAB_ROOT/k8s/alerts.yaml"
step "Waiting for the scores to evaluate (rules run in group order; up to 90s)"
for _ in $(seq 1 18); do
  V=$(promql 'platform:health_score' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
  [[ "$V" != "no data" ]] && break; sleep 5
done
[[ "$V" != "no data" ]] || die "platform:health_score has no data. Prometheus > Status > Rules — look for an evaluation error in 'health-scores'.
       Most likely: settlement metrics missing (no successful run yet), so the platform average has nothing to add."
step "Scores"
for s in activation egift settlement platform; do
  printf '  %-12s %s\n' "$s" "$(promql "${s}:health_score" | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')"
done
echo
say "Expected at the lab's baseline: activation ~82, egift ~80-90, settlement 100, platform ~85-90."
say "Activation is YELLOW on purpose: its 2% error rate is 4x over the 0.5% budget. A score that"
say "reads green while a service is over budget is lying. docs/health-score.md has the opinion."
ok "Next: import dashboards/overview.json, then ./scripts/61-score-sanity.sh"
