#!/usr/bin/env bash
# Day 4, Steps 1-2 — Tempo (trace store) + OpenTelemetry Collector, and register
# Tempo in Grafana as code.

source "$(dirname "$0")/lib.sh"
require_cluster

step "Helm repos"
# FIX: the PDF runs `helm install tempo grafana/tempo` but never adds the grafana repo.
# Days 1-3 only added prometheus-community and fluent. "repo grafana not found".
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update grafana open-telemetry >/dev/null
ok "grafana + open-telemetry"

step "Tempo"
helm upgrade --install tempo grafana/tempo \
  --kube-context "$KUBE_CONTEXT" -n "$TRACING_NS" --create-namespace \
  -f "$LAB_ROOT/k8s/tempo-values.yaml" --wait --timeout 5m
ok "tempo installed"

step "OpenTelemetry Collector"
helm upgrade --install otel open-telemetry/opentelemetry-collector \
  --kube-context "$KUBE_CONTEXT" -n "$TRACING_NS" \
  -f "$LAB_ROOT/k8s/otel-values.yaml" --wait --timeout 5m
ok "collector installed"

step "Services in $TRACING_NS"
k get svc -n "$TRACING_NS"
echo
dim "Apps send to    otel-opentelemetry-collector.tracing:4317   (OTLP over gRPC)"
dim "Collector sends to  tempo.tracing:4317"
dim "Grafana queries     tempo.tracing:3200   <- NOT 3100. 3100 is Loki. The PDF has it wrong."
dim "OTLP = the OpenTelemetry protocol. 4317 gRPC, 4318 HTTP. You will see these everywhere."

step "Registering Tempo as a Grafana datasource (as code)"
k apply -f "$LAB_ROOT/k8s/grafana-datasource-tempo.yaml"
dim "Grafana's sidecar picks this up within ~60s. Check: Connections > Data sources > Tempo."
dim "This replaces the PDF's click-through and survives Grafana restarts."

step "Confirming Tempo answers"
PF_PID=""; cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }; trap cleanup EXIT INT TERM
k port-forward svc/tempo -n "$TRACING_NS" 3200:3200 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
if curl -fsS --max-time 5 http://localhost:3200/ready >/dev/null 2>&1; then
  ok "Tempo /ready OK"
else
  warn "Tempo not ready yet — it usually takes a minute after the pod starts. Not fatal."
fi
ok "Next: ./scripts/31-instrument-activation.sh"
