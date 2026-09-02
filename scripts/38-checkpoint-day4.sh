#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0
t_ok()   { ok   "$*"; PASS=$((PASS+1)); }
t_fail() { warn "$*"; FAIL=$((FAIL+1)); }
step "Day 4 exit criteria"
for d in tempo otel-opentelemetry-collector; do
  R=$(kubectl --context "$KUBE_CONTEXT" get deploy "$d" -n "$TRACING_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  [[ "${R:-0}" -ge 1 ]] && t_ok "$d ready" || t_fail "$d not ready in $TRACING_NS"
done
IMG=$(kubectl --context "$KUBE_CONTEXT" get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
[[ "$IMG" == "activation:0.3" ]] && t_ok "activation on 0.3" || t_fail "activation is '${IMG:-none}', expected 0.3"
IMG=$(kubectl --context "$KUBE_CONTEXT" get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
[[ "$IMG" == "egift:0.1" ]] && t_ok "egift on 0.1" || t_fail "egift is '${IMG:-none}'"
for d in activation egift; do
  if kubectl --context "$KUBE_CONTEXT" get deploy "$d" -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | grep -q OTEL_SERVICE_NAME; then
    t_ok "$d has OTEL_* env"; else t_fail "$d missing OTEL_* env"; fi
done
R=$(promql 'sum(rate(egift_orders_total[2m]))' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.2f}'); [[ "$R" == "no data" ]] && R=0
python3 -c "import sys; sys.exit(0 if float('$R')>0.2 else 1)" && t_ok "egift traffic flowing (${R}/s)" || t_fail "no egift traffic (33-loadgen-egift.sh)"
[[ -s "$CHECKPOINTS/day4-sample-trace-id.txt" ]] && t_ok "cross-service trace verified (34-verify-traces.sh)" || t_fail "run 34-verify-traces.sh"
for f in INC-0002.md INC-0003.md; do [[ -s "$LAB_ROOT/incidents/$f" ]] && t_ok "$f present" || t_fail "$f missing"; done
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 4 complete. Day 5: SLIs, SLOs, error budgets, and the silent failure." || die "Not done yet."
