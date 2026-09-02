#!/usr/bin/env bash
# Day 5, Step 5 — burn the error budget on purpose and watch the BurnFast alert.
#
# FIX vs the PDF: it says set ERROR_RATE=0.10 and the alert fires "after about two
# minutes". It cannot. The rule gates on the 1-HOUR window exceeding 7.2%, and
# averaging up from a 2% baseline at 10% errors takes ~39 minutes. That is the rule
# working as designed — long windows move slowly, which is the whole point. We inject
# 0.50 instead so the 1h window crosses in ~6.5 min, and print the ETA.
#
# Usage: ./scripts/41-burn-budget.sh [error_rate]   (default 0.50)

source "$(dirname "$0")/lib.sh"
require_cluster
BAD="${1:-0.50}"; GOOD="0.02"; BUDGET=0.005; THRESH=$(python3 -c "print(14.4*$BUDGET)")

INJECTED=0; PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  if (( INJECTED )); then warn "reverting ERROR_RATE=$GOOD on exit"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" ERROR_RATE=$GOOD >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM
SVC="${PROM_SVC:-$(prom_svc || true)}"; [[ -n "$SVC" ]] || die "no Prometheus svc"
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 & PF_PID=$!; sleep 4
q() { curl -fsS --get --data-urlencode "query=$1" http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value "$2"; }
state() { curl -fsS http://localhost:9090/api/v1/rules | python3 "$LAB_ROOT/tools/promjson.py" rules ActivationErrorBudgetBurnFast | awk '{print $1}'; }
snap() { printf '  burn 5m=%-7s 1h=%-7s BurnFast=%s\n' "$(q 'activation:error_budget_burn_rate:5m' '{:.1f}x')" "$(q 'activation:error_budget_burn_rate:1h' '{:.1f}x')" "$(state)"; }

step "Baseline"; snap
ETA=$(python3 -c "
b=$BAD; base=0.02; th=$THRESH
t=(60*(th-base))/(b-base) if b>th else float('inf')
print(f'{t:.1f}')")
say "  Injecting ERROR_RATE=$BAD. 1h window crosses ${THRESH} (14.4x budget) in ~${ETA} min, then for: 2m."
say "  Expected page in ~$(python3 -c "print(round(float('$ETA')+2.5))") minutes. Open the 'Activation SLO' dashboard and watch the burn-rate panel."
read -rp "  Enter to inject. " _

step "Injecting"
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=$BAD"; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s

step "Watching (max 20 min)"
FIRED=0
for ((i=30; i<=1200; i+=30)); do
  sleep 30; printf '  t+%-5ss' "${i}"; snap
  [[ "$(state)" == "FIRING" ]] && { FIRED=1; break; }
done
if (( FIRED )); then
  ok "ActivationErrorBudgetBurnFast is FIRING"
  say "  Note the message: not 'errors are high' — 'the month is gone in two days'."
  say "  That is the sentence leadership understands."
else
  warn "did not fire in 20 min — check Prometheus > Alerts and the burn-rate panel"
fi

step "Rolling back"
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=$GOOD"; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
say "  The 5m window drops below threshold in ~4.5 min; the alert resolves then, even"
say "  though the 1h window stays high for most of an hour. That is what the short"
say "  window is FOR."
for ((i=30; i<=420; i+=30)); do sleep 30; printf '  t+%-5ss' "$i"; snap; [[ "$(state)" == "ok" ]] && break; done
S=$(state); [[ "$S" == "ok" ]] && ok "resolved" || warn "still ${S}; give it another minute"
say "  Write it up: incidents/INC-0004.md"
