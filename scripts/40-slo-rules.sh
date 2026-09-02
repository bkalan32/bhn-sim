#!/usr/bin/env bash
# Day 5, Steps 2-3 — recording rules + burn-rate alerts, and proof they loaded.
source "$(dirname "$0")/lib.sh"
require_cluster

step "Applying k8s/alerts.yaml (now 3 groups: activation, activation-slo, settlement)"
k apply -f "$LAB_ROOT/k8s/alerts.yaml"

SVC="${PROM_SVC:-$(prom_svc || true)}"; [[ -n "$SVC" ]] || { show_monitoring_svcs; die "no Prometheus svc"; }
PF_PID=""; cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }; trap cleanup EXIT INT TERM
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 & PF_PID=$!; sleep 4

step "Waiting for the recording rules to produce data (up to 90s)"
for _ in $(seq 1 18); do
  V=$(curl -fsS --get --data-urlencode 'query=activation:sli_availability:ratio_rate5m' http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value '{:.4f}')
  [[ "$V" != "no data" ]] && break; sleep 5
done
[[ "$V" != "no data" ]] || die "recording rules not producing. Prometheus > Status > Rules; check the release: kps label."

step "Current SLIs and burn rates"
q() { curl -fsS --get --data-urlencode "query=$1" http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value "$2"; }
printf '  availability SLI (5m)   %s\n'  "$(q 'activation:sli_availability:ratio_rate5m * 100' '{:.2f}%')"
printf '  latency SLI (5m)        %s   (target 99%% under 300ms)\n' "$(q 'activation:sli_latency:ratio_rate5m * 100' '{:.2f}%')"
printf '  burn rate 5m / 1h / 6h  %s / %s / %s\n' "$(q 'activation:error_budget_burn_rate:5m' '{:.1f}x')" "$(q 'activation:error_budget_burn_rate:1h' '{:.1f}x')" "$(q 'activation:error_budget_burn_rate:6h' '{:.1f}x')"
echo
say "Read the burn rate. At the 2% baseline it should be ~4x."
say "That means the service is quietly OVER budget, permanently, and no alert will ever"
say "say so — the fast rule needs 14.4x, the slow rule 6x. That gap is deliberate: over"
say "budget is a roadmap problem; burning fast is an incident. Write the 4x down in"
say "docs/slos.md as a real finding."

step "Alert rules loaded"
curl -fsS http://localhost:9090/api/v1/rules | python3 "$LAB_ROOT/tools/promjson.py" rules Activation
curl -fsS http://localhost:9090/api/v1/rules | python3 "$LAB_ROOT/tools/promjson.py" rules Settlement || true
ok "Next: import dashboards/activation-slo.json, then ./scripts/41-burn-budget.sh"
