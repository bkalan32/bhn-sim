#!/usr/bin/env bash
# Day 1, Step 4 — create the cluster. From here on, this cluster is "production".

source "$(dirname "$0")/lib.sh"
require_docker

step "Creating kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "Cluster '${CLUSTER_NAME}' already exists — skipping create"
else
  kind create cluster --config "$LAB_ROOT/kind/bhn-sim-cluster.yaml"
fi

step "Context"
say "kind names contexts with a 'kind-' prefix, so yours is:"
ok "$KUBE_CONTEXT"
dim "This is the single most common Day 1 confusion. 'kubectl config use-context bhn-sim' will NOT work."
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

step "Waiting for the node to report Ready"
k wait --for=condition=Ready node --all --timeout=180s
k get nodes -o wide

step "Cluster is up"
ok "Next: scripts/04-smoke-test.sh"
