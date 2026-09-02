#!/usr/bin/env bash
# Day 4, Step 4 — build and deploy the eGift service.

source "$(dirname "$0")/lib.sh"
require_docker
require_cluster

step "Building egift:0.1"
build_service egift 0.1

step "Deploying k8s/egift.yaml"
k apply -f "$LAB_ROOT/k8s/egift.yaml"
k rollout status deployment/egift -n "$PAYMENTS_NS" --timeout=180s
k get pods -n "$PAYMENTS_NS" -o wide

step "Can egift reach activation? (the PDF's #1 troubleshooting item, checked up front)"
POD=$(k get pods -n "$PAYMENTS_NS" -l app=egift -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$POD" ]] && k exec -n "$PAYMENTS_NS" "$POD" -- python3 -c \
   'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen("http://activation.payments:8000/healthz",timeout=3).status==200 else 1)' 2>/dev/null; then
  ok "egift pod can reach activation.payments:8000"
else
  warn "egift cannot reach activation. Check: kubectl get svc -n payments"
fi

step "One real order through the NodePort"
RESP=$(curl -s --max-time 10 -X POST http://localhost:30443/orders \
  -H 'Content-Type: application/json' \
  -d '{"customer_id":"CORP-0001","amount":50,"recipient_email":"sales@corp1.example"}' || true)
if [[ "$RESP" == *order_id* ]]; then
  ok "$RESP"
else
  warn "no order_id in response: ${RESP:-<empty>}. Is 30443 mapped on your kind node? (kind/bhn-sim-cluster.yaml)"
fi
ok "Next: ./scripts/33-loadgen-egift.sh  (terminal #6, leave running)"
