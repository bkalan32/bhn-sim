#!/usr/bin/env bash
# Day 3, Step 7 — break the fraud dependency and watch the full chain react.
#
# This is the first drill where all three layers speak:
#   alert  says  "errors"            (Prometheus)
#   dashboard says "everything, and slow"  (Grafana)
#   logs   say   "it's the fraud dependency"  (Splunk)
#
# Usage: ./scripts/24-incident-fraud.sh [hold_seconds]   (default 300)

source "$(dirname "$0")/lib.sh"
require_cluster
INJECTED=0
revert_on_exit() { if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap revert_on_exit EXIT

HOLD="${1:-300}"

SVC="${PROM_SVC:-$(prom_svc || true)}"
[[ -n "$SVC" ]] || { show_monitoring_svcs; die "Prometheus service not found."; }

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
sleep 4

snapshot() {
  local err p95 state
  err=$(curl -fsS --get --data-urlencode \
      'query=100 * sum(rate(activation_requests_total{status="error"}[2m])) / clamp_min(sum(rate(activation_requests_total[2m])), 0.001)' \
      http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value '{:.1f}%')
  p95=$(curl -fsS --get --data-urlencode \
      'query=histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[2m])) by (le))' \
      http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value '{:.2f}s')
  state=$(curl -fsS http://localhost:9090/api/v1/rules \
      | python3 "$LAB_ROOT/tools/promjson.py" rules ActivationHighErrorRate | awk '{print $1}')
  printf '  err=%-7s p95=%-7s ActivationHighErrorRate=%s\n' "$err" "$p95" "${state:-?}"
}

step "Baseline"
snapshot

step "Open these before you continue"
say "  Grafana        http://localhost:3000    (./scripts/06-grafana.sh)"
say "  Prometheus     http://localhost:9090/alerts"
say "  Alertmanager   kubectl port-forward svc/$(alertmanager_svc || echo '<alertmanager>') -n monitoring 9093:9093"
say "  Splunk         http://localhost:8000"
echo
read -rp "Ready? Press Enter to break the fraud service. " _

step "Injecting: FRAUD_SVC_DOWN=true"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
dim "Traffic keeps flowing through the NodePort during the rollout — that is why we"
dim "stopped using a port-forward for load. Watch the error rate, not the terminal."

step "Holding ${HOLD}s. Expect: error rate -> 100%, p95 -> 3s+, alert Inactive -> Pending -> Firing"
for ((i=30; i<=HOLD; i+=30)); do
  sleep 30
  printf '  t+%-4ss' "$i"; snapshot
done

step "The question the logs answer"
say "  In Splunk, run:"
say "    index=main app.service=activation app.status=error earliest=-5m | stats count by app.reason"
say "  Expected answer: fraud_service_timeout"
echo
dim "That is the moment the incident becomes diagnosable. The alert said 'errors'. The"
dim "dashboard said 'everything, and slow'. Only the logs name the dependency."
echo
read -rp "Ran the search? Press Enter to recover. " _

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s

step "Watching it resolve"
for i in 1 2 3 4 5 6; do sleep 30; printf '  t+%-4ss' "$((i*30))"; snapshot; done

step "Write it up"
say "  incidents/INC-0001.md is scaffolded — fill in the timestamps and your own answers."
dim "The follow-up bullet is the one that matters: should activation fail fast when fraud"
dim "is down, instead of waiting 3 seconds for a result it will never get?"
dim "That is the difference between fixing an incident and engineering it away."
