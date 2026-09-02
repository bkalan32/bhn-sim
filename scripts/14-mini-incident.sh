#!/usr/bin/env bash
# Day 2, Step 8 — your first mini-incident.
#
# See it, change something, confirm recovery on the dashboard. That loop is the core
# of incident response. Everything else is process wrapped around it.
#
# Usage: ./scripts/14-mini-incident.sh [error_rate] [hold_seconds]

source "$(dirname "$0")/lib.sh"
require_cluster
INJECTED=0
revert_on_exit() { if (( INJECTED )); then warn "exiting mid-drill — reverting ERROR_RATE=0.02"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" ERROR_RATE=0.02 >/dev/null 2>&1 || true; fi; }
trap revert_on_exit EXIT

BAD_RATE="${1:-0.30}"
HOLD="${2:-180}"
GOOD_RATE="0.02"

measure() {
  promql '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])), 0.001)' \
    | python3 "$LAB_ROOT/tools/promjson.py" value '{:.1f}%'
}

step "Baseline error rate"
say "  $(measure)"

step "Injecting failure: ERROR_RATE=${BAD_RATE}"
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=${BAD_RATE}"; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=120s
dim "Note this rolls the pods. New pods mean counters restart from zero — that is fine,"
dim "PromQL's rate() detects counter resets and handles them. Watch the dashboard now."

step "Holding for ${HOLD}s — watch Grafana"
for ((i=30; i<=HOLD; i+=30)); do
  sleep 30
  printf '  t+%-4ss  error rate: %s\n' "$i" "$(measure)"
done

step "Rolling back: ERROR_RATE=${GOOD_RATE}"
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=${GOOD_RATE}"; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=120s

step "Waiting for recovery"
for i in 1 2 3 4; do sleep 30; printf '  t+%-4ss  error rate: %s\n' "$((i*30))" "$(measure)"; done

step "Done"
say "You just caused an outage and recovered from it, and the graph proved both."
dim "Write down: what did you look at first? How long until you were sure it recovered?"
dim "Those two answers are 'time to detect' and 'time to verify' — real incident metrics."
