#!/usr/bin/env bash
# Day 3, Step 1 — ship v0.2 with structured JSON logging.
#
# FIX vs the PDF: the PDF upgrades with `kubectl set image deployment/activation ...`
# but never updates k8s/activation.yaml, which still says activation:0.1. The cluster
# and the repo now disagree, and the next `kubectl apply -f` silently DOWNGRADES you
# back to 0.1 — losing your logging with no error message. That is config drift, and
# it is a genuinely common production incident.
# This repo bumps the manifest and applies it, so the file stays the source of truth.

source "$(dirname "$0")/lib.sh"
require_docker
require_cluster

cd "$LAB_ROOT/services/activation" || die "services/activation not found"

step "Building activation:0.2"
docker build --build-arg APP_VERSION=0.2 -t activation:0.2 .
ok "built"

step "Loading into kind"
kind load docker-image activation:0.2 --name "$CLUSTER_NAME"

step "Applying the manifest (declarative — the file is the source of truth)"
grep -q 'image: activation:0.2' "$LAB_ROOT/k8s/activation.yaml" \
  || die "k8s/activation.yaml still pins an older image. Fix the file, not the cluster."
k apply -f "$LAB_ROOT/k8s/activation.yaml"
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s

step "Confirming the running version"
k get pods -n "$PAYMENTS_NS" -l app=activation \
  -o jsonpath='{range .items[*]}  {.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'

step "Structured logs"
dim "kubectl logs is the raw way to read logs. It works for one service."
dim "It does not work when you have two hundred. That is what Splunk is for."
sleep 3
k logs -n "$PAYMENTS_NS" -l app=activation --tail=6 | python3 "$LAB_ROOT/tools/logfmt.py"

ok "Next: scripts/21-splunk-up.sh"
