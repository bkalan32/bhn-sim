#!/usr/bin/env bash
# Day 3, Step 6 — the first alert rules, and proof Prometheus actually loaded them.

source "$(dirname "$0")/lib.sh"
require_cluster

step "Applying k8s/alerts.yaml"
k apply -f "$LAB_ROOT/k8s/alerts.yaml"

step "Checking the release label"
REL=$(k get prometheusrule activation-alerts -n "$PAYMENTS_NS" -o jsonpath='{.metadata.labels.release}' 2>/dev/null || true)
[[ "$REL" == "$HELM_RELEASE" ]] && ok "release='$REL' matches Helm release '$HELM_RELEASE'" \
  || die "release='$REL' but Helm release is '$HELM_RELEASE'. The Operator will ignore this file silently."

step "Waiting for the Operator to reload the rules (up to 60s)"
SVC="${PROM_SVC:-$(prom_svc || true)}"
[[ -n "$SVC" ]] || { show_monitoring_svcs; die "Prometheus service not found."; }

PF_PID=""
cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 &
PF_PID=$!
sleep 4

FOUND=0
for _ in $(seq 1 12); do
  if curl -fsS http://localhost:9090/api/v1/rules 2>/dev/null | grep -q ActivationHighErrorRate; then
    FOUND=1; break
  fi
  sleep 5
done
(( FOUND )) || die "Rules never appeared in Prometheus after 60s.
       The Operator reloads on a timer; check: kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator"

step "Loaded rules"
curl -fsS http://localhost:9090/api/v1/rules | python3 "$LAB_ROOT/tools/promjson.py" rules activation

step "Alert design — read this, it is a named responsibility in the job"
say "  > 10, not > 0     the service has a 2% baseline. Alerting on any error pages you"
say "                    constantly. That is alert fatigue, and reducing it is part of the role."
say "  for: 2m           the condition must HOLD for two minutes. A ten-second blip does"
say "                    not wake anyone up."
say "  critical vs warning   errors mean cards are not being sold. Slow but working is a warning."
say "  the annotation    is what a human reads at 3 AM. It must make sense with no context,"
say "                    which is why ours names the impact and links the next query to run."
echo
dim "Added beyond the PDF: ActivationNoTraffic. If traffic stops, every other rule goes"
dim "quiet — not because things are healthy, but because there is nothing to measure."
dim "'No data' has to be its own alert or it is a blind spot. You hit exactly this on Day 2."
ok "Next: ./scripts/24-incident-fraud.sh"
