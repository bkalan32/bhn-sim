#!/usr/bin/env bash
# Day 4, Step 6 — prove a trace crosses both services, and print the waterfall.

source "$(dirname "$0")/lib.sh"
require_cluster

PF_PID=""; cleanup() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }; trap cleanup EXIT INT TERM
step "Port-forwarding Tempo :3200"
k port-forward svc/tempo -n "$TRACING_NS" 3200:3200 >/dev/null 2>&1 &
PF_PID=$!; sleep 3
curl -fsS --max-time 5 http://localhost:3200/ready >/dev/null 2>&1 || die "Tempo not ready on :3200"

step "Recent egift traces"
NOW=$(date +%s); START=$((NOW-600))
SEARCH=$(curl -fsS --get "http://localhost:3200/api/search" \
  --data-urlencode 'q={ resource.service.name = "egift" && name = "POST /orders" }' \
  --data-urlencode "start=${START}" --data-urlencode "end=${NOW}" \
  --data-urlencode "limit=5" 2>/dev/null || echo '{}')
echo "$SEARCH" | python3 "$LAB_ROOT/tools/tempojson.py" search || {
  dim "No traces yet. Is 33-loadgen-egift.sh running? Traces take ~10-30s to land."
  dim "Collector logs: kubectl logs -n tracing -l app.kubernetes.io/name=opentelemetry-collector --tail=20"
  die "nothing to verify"
}
TID=$(echo "$SEARCH" | python3 -c 'import json,sys; t=json.load(sys.stdin).get("traces",[]); print(t[0]["traceID"] if t else "")')

step "Waterfall for $TID"
TRACE=$(curl -fsS "http://localhost:3200/api/traces/${TID}" 2>/dev/null || echo '{}')
echo "$TRACE" | python3 "$LAB_ROOT/tools/tempojson.py" waterfall
echo
say "Read it top to bottom. One customer request, two services, and you can see exactly"
say "where the time went. This is the view that ends the 'is it us or them?' argument."

step "Both services present in one trace?"
echo "$TRACE" | python3 "$LAB_ROOT/tools/tempojson.py" services egift activation \
  || die "activation spans missing. Was it rebuilt as 0.3 under opentelemetry-instrument? Check OTEL_* env: kubectl describe pod -n payments -l app=activation"
ok "cross-service trace confirmed"

step "Now correlate to logs. In Splunk:"
say "  index=main app.trace_id=${TID}"
dim "Both services' log lines for this single request appear together."
echo "$TID" > "$CHECKPOINTS/day4-sample-trace-id.txt"
ok "Also: Grafana > Explore > Tempo > paste the ID, or Search by Service Name = egift"
