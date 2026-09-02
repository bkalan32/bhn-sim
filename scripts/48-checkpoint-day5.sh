#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 5 exit criteria"
[[ -s "$LAB_ROOT/docs/slos.md" ]] && t_ok "docs/slos.md" || t_fail "docs/slos.md missing"
V=$(promql 'activation:sli_availability:ratio_rate5m' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.3f}')
[[ "$V" != "no data" ]] && t_ok "recording rules producing (avail 5m = $V)" || t_fail "recording rules not producing (40-slo-rules.sh)"
if kubectl --context "$KUBE_CONTEXT" get prometheusrule activation-alerts -n "$PAYMENTS_NS" -o yaml 2>/dev/null | grep -q ActivationErrorBudgetBurnFast; then t_ok "burn-rate alerts loaded"; else t_fail "burn-rate alerts missing"; fi
kubectl --context "$KUBE_CONTEXT" get cronjob settlement -n "$PAYMENTS_NS" >/dev/null 2>&1 && t_ok "settlement CronJob exists" || t_fail "settlement CronJob missing (43-build-settlement.sh)"
V=$(promql 'settlement_records_processed' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
[[ "$V" != "no data" ]] && t_ok "settlement metrics in Prometheus (last run: $V records)" || t_fail "no settlement metrics"
M=$(kubectl --context "$KUBE_CONTEXT" get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_FAIL_MODE")].value}' 2>/dev/null || echo "?")
[[ "$M" == "none" ]] && t_ok "CronJob back at FAIL_MODE=none" || t_fail "CronJob still in FAIL_MODE=$M (44-settlement-failure.sh none)"
for f in INC-0004.md INC-0005.md; do [[ -s "$LAB_ROOT/incidents/$f" ]] && t_ok "$f" || t_fail "$f missing"; done
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 5 complete. Day 6: CI/CD, a bad deploy, and the rollback." || die "Not done yet."
