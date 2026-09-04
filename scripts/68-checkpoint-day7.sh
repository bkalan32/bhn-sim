#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 7 exit criteria"
for s in activation egift settlement platform; do
  V=$(promql "${s}:health_score" | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
  [[ "$V" != "no data" ]] && t_ok "${s}:health_score = $V" || t_fail "${s}:health_score has no data"
done
[[ -s "$LAB_ROOT/docs/health-score.md" ]] && t_ok "docs/health-score.md" || t_fail "docs/health-score.md missing"
[[ -s "$LAB_ROOT/docs/week1-review.md" ]] && t_ok "docs/week1-review.md" || t_fail "docs/week1-review.md missing"
[[ -s "$LAB_ROOT/dashboards/overview.json" ]] && t_ok "dashboards/overview.json" || t_fail "overview.json missing"
CT=$(kubectl --context "$KUBE_CONTEXT" get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FRAUD_CLIENT_TIMEOUT_S")].value}' 2>/dev/null || true)
[[ "$CT" == "0.3" ]] && t_ok "fail-fast build deployed (FRAUD_CLIENT_TIMEOUT_S=0.3)" || t_fail "fail-fast not deployed — run the pipeline"
kubectl --context "$KUBE_CONTEXT" rollout history deployment/activation -n "$PAYMENTS_NS" 2>/dev/null | grep -qi 'fail fast' && t_ok "rollout history shows the fail-fast deploy" || t_fail "no 'fail fast' change-cause in history"
grep -q 'fix verified' "$LAB_ROOT/incidents/INC-0001.md" 2>/dev/null && t_ok "INC-0001 has a 'fix verified' line" || t_fail "INC-0001.md lacks 'fix verified' — add before/after numbers"
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Week 1 complete. Day 8: Alertmanager routing into your own incident bot." || die "Not done yet."
