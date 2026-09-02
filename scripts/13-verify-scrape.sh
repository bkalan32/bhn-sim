#!/usr/bin/env bash
# Day 2, Step 5 — is Prometheus actually scraping the service?
#
# FIX vs the PDF: rather than eyeballing Status > Targets in the UI, this queries the
# Prometheus API directly, so it is a pass/fail check you can re-run any time.

source "$(dirname "$0")/lib.sh"
require_cluster

step "Locating the Prometheus service"
SVC="${PROM_SVC:-}"
if [[ -n "$SVC" ]]; then ok "using PROM_SVC=$SVC"; fi
[[ -n "$SVC" ]] || SVC="$(prom_svc || true)"
if [[ -z "$SVC" ]]; then
  show_monitoring_svcs
  die "Could not identify the Prometheus service automatically.
       Pick the one ending in '-prometheus' from the list above and re-run as:
         PROM_SVC=<name> $0"
fi
ok "svc/$SVC"
dim "Names in this chart depend on the Helm release name and a 26-character truncation"
dim "rule, and the labels differ between chart versions. Look it up, do not memorise it:"
dim "  kubectl get svc -n monitoring | grep prometheus"

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

step "Port-forwarding Prometheus to :9090"
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
sleep 4

step "Targets named 'activation'"
TARGETS=$(curl -fsS http://localhost:9090/api/v1/targets 2>/dev/null) || die "Prometheus API unreachable."
echo "$TARGETS" | python3 "$LAB_ROOT/tools/promjson.py" targets activation \
  || die "At least one activation target is not UP."
ok "all activation targets UP"

step "Live numbers"
for q in 'sum(rate(activation_requests_total[1m]))' \
         '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])), 0.001)' \
         'histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[1m])) by (le))'; do
  V=$(curl -fsS --get --data-urlencode "query=$q" http://localhost:9090/api/v1/query \
      | python3 "$LAB_ROOT/tools/promjson.py" value)
  printf '  %-8s %s\n' "$V" "$q"
done
echo
dim "Expected once the load generator has run for a minute or two:"
dim "  request rate ~5-8 req/s, error rate ~2%, p95 latency ~0.1s. That is 'normal'."
dim "'no data' on all three means counters do not exist yet — send some traffic first."
ok "Next: build the dashboard (scripts/../dashboards/activation.json), then 14-mini-incident.sh"
