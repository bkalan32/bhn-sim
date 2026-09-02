#!/usr/bin/env bash
# Day 5, Step 6 — Pushgateway. A batch job runs for 30s and exits; Prometheus scrapes
# every 15s and would usually miss it. The Pushgateway is somewhere scrapable for
# short-lived jobs to leave their final numbers.
source "$(dirname "$0")/lib.sh"
require_cluster

step "Installing prometheus-pushgateway into $MONITORING_NS"
helm repo update prometheus-community >/dev/null 2>&1 || true
helm upgrade --install pushgateway prometheus-community/prometheus-pushgateway \
  --kube-context "$KUBE_CONTEXT" -n "$MONITORING_NS" \
  --set serviceMonitor.enabled=true \
  --set serviceMonitor.additionalLabels.release="$HELM_RELEASE" \
  --set serviceMonitor.honorLabels=true \
  --set resources.requests.cpu=10m --set resources.requests.memory=32Mi \
  --set resources.limits.memory=128Mi \
  --wait --timeout 3m
ok "installed"

step "Service name (the job pushes to this)"
SVC=$(k get svc -n "$MONITORING_NS" -o name | sed 's|service/||' | grep -i pushgateway | head -1 || true)
[[ -n "$SVC" ]] || die "no pushgateway service found"
ok "$SVC.$MONITORING_NS:9091"
grep -q "value: ${SVC}.${MONITORING_NS}:9091" "$LAB_ROOT/k8s/settlement.yaml" \
  && ok "k8s/settlement.yaml PUSHGATEWAY matches" \
  || warn "k8s/settlement.yaml PUSHGATEWAY does not match '$SVC' — edit it before deploying the job"
dim "honorLabels=true keeps the job's own job=\"settlement\" label instead of renaming it"
dim "exported_job — without it, every query in the PDF still works but the label is wrong."
ok "Next: ./scripts/43-build-settlement.sh"
