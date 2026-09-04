#!/usr/bin/env bash
# Day 7, Step 7 — re-run INC-0001 against the fail-fast build and measure the difference.
# Run this AFTER the pipeline has deployed v0.4 (check: Running versions panel, or
# kubectl get deploy activation -n payments -o jsonpath='{.spec.template.spec.containers[0].image}')
source "$(dirname "$0")/lib.sh"
require_cluster
HOLD="${1:-180}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "reverting FRAUD_SVC_DOWN=false on exit"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM
q(){ promql "$1" | python3 "$LAB_ROOT/tools/promjson.py" value "$2"; }
snap(){ printf '  act err=%-7s act p95=%-7s egift p95=%-7s egift rate=%s\n' \
  "$(q '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])),0.001)' '{:.0f}%')" \
  "$(q 'histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[1m])) by (le))' '{:.2f}s')" \
  "$(q 'histogram_quantile(0.95, sum(rate(egift_order_latency_seconds_bucket[1m])) by (le))' '{:.2f}s')" \
  "$(q 'sum(rate(egift_orders_total[1m]))' '{:.1f}/s')"; }

step "Which build is running?"
CT=$(k get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FRAUD_CLIENT_TIMEOUT_S")].value}' 2>/dev/null || true)
IMG=$(k get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
say "  image=$IMG   FRAUD_CLIENT_TIMEOUT_S=${CT:-<unset — old build, will hang 3s>}"
[[ -n "$CT" ]] || warn "The fail-fast build is not deployed. Run the pipeline first (CHANGE_CAUSE='fail fast on fraud dependency (INC-0001 follow-up)')."

step "Baseline"; snap
read -rp "  Enter to break the fraud service (same as Day 3). " _
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
step "Holding ${HOLD}s — compare to Day 3: p95 was ~3s, eGift stacked multi-second waits"
for ((i=30;i<=HOLD;i+=30)); do sleep 30; printf '  t+%-4ss' "$i"; snap; done
step "Recovering"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
for i in 1 2 3; do sleep 30; printf '  t+%-4ss' "$((i*30))"; snap; done
step "Write it down"
say "  Error rate still 100% during the outage — CORRECT. Fraud checks are not optional."
say "  p95 ~0.3s instead of ~3s; eGift barely moved. Same outage, a fraction of the blast radius."
say "  Put the before/after in docs/week1-review.md and a 'fix verified' line in INC-0001."
