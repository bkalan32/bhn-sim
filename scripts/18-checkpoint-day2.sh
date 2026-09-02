#!/usr/bin/env bash
# Day 2 exit criteria, as an actual test.

source "$(dirname "$0")/lib.sh"

PASS=0; FAIL=0
t_ok()   { ok   "$*"; PASS=$((PASS+1)); }
t_fail() { warn "$*"; FAIL=$((FAIL+1)); }

step "Day 2 exit criteria"

READY=$(kubectl --context "$KUBE_CONTEXT" get deploy activation -n "$PAYMENTS_NS" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
[[ "${READY:-0}" == "2" ]] && t_ok "two activation pods Ready" \
                           || t_fail "readyReplicas=${READY:-0}, expected 2"

if kubectl --context "$KUBE_CONTEXT" get servicemonitor activation -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  t_ok "ServiceMonitor exists"
else
  t_fail "ServiceMonitor missing"
fi

R=$(promql 'sum(rate(activation_requests_total[1m]))' \
     | python3 "$LAB_ROOT/tools/promjson.py" value '{:.2f}')
[[ "$R" == "no data" ]] && R=0
python3 -c "import sys; sys.exit(0 if float('$R')>0.5 else 1)" 2>/dev/null \
  && t_ok "Prometheus sees traffic (${R} req/s)" \
  || t_fail "request rate is ${R} — is the load generator running? (scripts/12-loadgen.sh)"

[[ -s "$LAB_ROOT/dashboards/activation.json" ]] && t_ok "dashboards/activation.json committed" \
                                                || t_fail "dashboards/activation.json missing"

if git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q .; then
  warn "uncommitted changes — commit before you call Day 2 done"
else
  t_ok "working tree clean"
fi

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 2 complete. Day 3 adds structured logging, Splunk, and the first real alert." \
                || die "Not done yet — see the failures above."
