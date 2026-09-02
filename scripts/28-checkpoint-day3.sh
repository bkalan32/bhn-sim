#!/usr/bin/env bash
# Day 3 exit criteria.

source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0
t_ok()   { ok   "$*"; PASS=$((PASS+1)); }
t_fail() { warn "$*"; FAIL=$((FAIL+1)); }

step "Day 3 exit criteria"

IMG=$(kubectl --context "$KUBE_CONTEXT" get deploy activation -n "$PAYMENTS_NS" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
[[ "$IMG" == "activation:0.2" ]] && t_ok "running $IMG" || t_fail "image is '${IMG:-none}', expected activation:0.2"

if kubectl --context "$KUBE_CONTEXT" logs -n "$PAYMENTS_NS" -l app=activation --tail=20 2>/dev/null \
   | grep -q '"service":"activation"'; then
  t_ok "service is emitting JSON logs"
else
  t_fail "no JSON log lines found — is the load generator running?"
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx splunk; then
  t_ok "Splunk container running"
else
  t_fail "Splunk container not running (./scripts/21-splunk-up.sh)"
fi

if kubectl --context "$KUBE_CONTEXT" get pods -n "$LOGGING_NS" 2>/dev/null | grep -q Running; then
  t_ok "Fluent Bit running"
else
  t_fail "Fluent Bit not running (./scripts/22-fluent-bit.sh <TOKEN>)"
fi

if kubectl --context "$KUBE_CONTEXT" get prometheusrule activation-alerts -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  t_ok "PrometheusRule activation-alerts exists"
else
  t_fail "PrometheusRule missing (./scripts/23-alerts.sh)"
fi

[[ -s "$LAB_ROOT/incidents/INC-0001.md" ]] && t_ok "INC-0001.md written" || t_fail "incidents/INC-0001.md missing"

if grep -q '_fill in_' "$LAB_ROOT/incidents/INC-0001.md" 2>/dev/null; then
  warn "INC-0001.md still has _fill in_ placeholders — the write-up IS the deliverable"
fi

if git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q .; then
  warn "uncommitted changes"
else
  t_ok "working tree clean"
fi

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 3 complete. Day 4: OpenTelemetry tracing and a second service." \
                || die "Not done yet."
