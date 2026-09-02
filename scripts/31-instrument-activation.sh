#!/usr/bin/env bash
# Day 4, Step 3 — activation v0.3: auto-instrumented, trace IDs in every log line.

source "$(dirname "$0")/lib.sh"
require_docker
require_cluster

step "Building activation:0.3 (with OpenTelemetry auto-instrumentation)"
dim "opentelemetry-bootstrap installs a lot. That is normal — it detects fastapi, requests"
dim "and friends and installs matching instrumentation packages."
build_service activation 0.3

step "Deploying (manifest already says 0.3 + OTEL_* env — declarative, no sed -i)"
dim "The PDF uses  sed -i '' ...  which is the macOS form. On Linux, -i '' hands sed an"
dim "empty script and the file name as a second script: 'can't read s/...: No such file'."
grep -q 'image: activation:0.3' "$LAB_ROOT/k8s/activation.yaml" || die "k8s/activation.yaml does not pin 0.3"
k apply -f "$LAB_ROOT/k8s/activation.yaml"
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s

step "Checking the OTEL env landed"
k get deploy activation -n "$PAYMENTS_NS" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep '^OTEL_' | sed 's/^/  /'

step "Log lines now carry a trace_id"
sleep 5
k logs -n "$PAYMENTS_NS" -l app=activation --tail=3 | grep -o '"trace_id":"[0-9a-f]*"' | head -3 | sed 's/^/  /' \
  || warn "no trace_id yet — needs a request to have gone through since the rollout"
ok "Next: ./scripts/32-build-egift.sh"
