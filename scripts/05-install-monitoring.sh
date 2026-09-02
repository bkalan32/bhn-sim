#!/usr/bin/env bash
# Day 1, Step 6 — Prometheus + Grafana + Alertmanager via kube-prometheus-stack.
#
# Two fixes vs the guide (see CORRECTIONS-DAY1.md B2, B3):
#   * it waits explicitly instead of telling you "wait a few minutes"
#   * it explains that the two admission-webhook pods END in Completed, not Running

source "$(dirname "$0")/lib.sh"
require_cluster

step "Adding the prometheus-community Helm repo"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
CHART_VER=$(helm search repo prometheus-community/kube-prometheus-stack -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["version"] if d else "unknown")' 2>/dev/null || echo unknown)
ok "chart version available: ${CHART_VER}  (should be 88.x — verified 88.6.2 on 2026-09-01)"
dim "The OCI form 'helm install kps oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack'"
dim "installs the identical chart if you prefer to skip the repo step."

step "Installing release '${HELM_RELEASE}' into namespace '${MONITORING_NS}'"
dim "Note the flag is --create-namespace, one token. The PDF line-wraps it as '--create-' + 'namespace'."
helm upgrade --install "$HELM_RELEASE" prometheus-community/kube-prometheus-stack \
  --kube-context "$KUBE_CONTEXT" \
  -n "$MONITORING_NS" --create-namespace \
  --wait --timeout 15m

step "Waiting for every pod to settle"
# --field-selector excludes the two admission Jobs, which finish as Completed and
# would make a plain 'wait --all' hang forever.
k wait --for=condition=Ready pod --all -n "$MONITORING_NS" \
  --field-selector=status.phase!=Succeeded --timeout=600s

step "Pod status"
k get pods -n "$MONITORING_NS"
echo
say "Expected end state, and this is where the guide misleads you:"
ok  "everything Running, EXCEPT"
ok  "kps-kube-prometheus-admission-create-*  ->  Completed"
ok  "kps-kube-prometheus-admission-patch-*   ->  Completed"
dim "Those two are Kubernetes Jobs. Completed IS success. Nothing should be Pending,"
dim "CrashLoopBackOff or Error. Pending here is almost always memory — see .wslconfig."

k get pods -n "$MONITORING_NS" > "$CHECKPOINTS/day1-monitoring-pods.txt"
step "What you just installed"
say "  Prometheus    collects metrics: request rate, error rate, CPU, memory"
say "  Grafana       turns those metrics into dashboards"
say "  Alertmanager  fires alerts when a metric crosses a threshold"
ok "Next: scripts/06-grafana.sh"
