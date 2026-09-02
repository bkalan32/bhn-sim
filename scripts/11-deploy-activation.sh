#!/usr/bin/env bash
# Day 2, Step 4 — deploy to the cluster and confirm Prometheus picks it up.

source "$(dirname "$0")/lib.sh"
require_cluster

step "Applying k8s/activation.yaml"
k apply -f "$LAB_ROOT/k8s/activation.yaml"

step "Applying k8s/activation-nodeport.yaml"
# A stable front door on localhost:30080 that load-balances across pods and survives
# rolling restarts. Without it, traffic rides a port-forward pinned to one pod, and
# every `kubectl set env` drops your load generator mid-drill.
k apply -f "$LAB_ROOT/k8s/activation-nodeport.yaml"

step "Waiting for the rollout"
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
k get pods -n "$PAYMENTS_NS" -o wide

step "What you just created"
say "  Namespace payments   a folder for business services, separate from monitoring"
say "  Deployment           two replicas, so one can die and the service stays up"
say "  Service              stable name activation.payments, load-balances across pods"
say "  NodePort Service     localhost:30080 front door that survives rolling restarts"
say "  ServiceMonitor       tells Prometheus to scrape /metrics every 15s"
echo
dim "The ServiceMonitor's 'release: kps' label is what makes Prometheus notice it."
dim "Without that label it is silently ignored — no error anywhere."

step "Confirming the ServiceMonitor label matches the Helm release"
SM_REL=$(k get servicemonitor activation -n "$PAYMENTS_NS" -o jsonpath='{.metadata.labels.release}' 2>/dev/null || true)
if [[ "$SM_REL" == "$HELM_RELEASE" ]]; then
  ok "ServiceMonitor release='$SM_REL' matches Helm release '$HELM_RELEASE'"
else
  warn "ServiceMonitor release='$SM_REL' but your Helm release is '$HELM_RELEASE'."
  warn "Prometheus will silently ignore this service. Edit the label in k8s/activation.yaml."
fi

ok "Next: scripts/12-loadgen.sh (traffic), then scripts/13-verify-scrape.sh"
