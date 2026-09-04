#!/usr/bin/env bash
# Day 8, Step 3 — one real incident through the whole chain:
#   fault -> Prometheus alert -> Alertmanager group -> webhook -> incident record
#   recovery -> alert resolves -> resolved webhook -> incident closed, duration filled in
#
# Usage: ./scripts/82-incident-drill.sh [hold_seconds]   (default 240)
#
# Timing you should EXPECT, so you do not think it is broken:
#   +0:00  FRAUD_SVC_DOWN=true, error rate -> 100% within the rollout
#   +2:00  ActivationHighErrorRate: Pending -> Firing (for: 2m)
#   +2:15  Alertmanager group_wait 15s -> webhook -> INCIDENT OPENS
#   +3:00  ActivationErrorBudgetBurnFast joins the SAME incident (its 5m window catches up)
#   recover at +4:00
#   +6:00  HighErrorRate clears (2m window drains) ... BurnFast needs its 5m window clear
#   +9:00  last alert resolves, group_interval 2m -> resolved webhook -> INCIDENT RESOLVED
# So: ~2.5 minutes to open, ~5-8 minutes after recovery to close. That closing lag is
# real-world too: incidents close when the signals clear, not when the fix lands.
source "$(dirname "$0")/lib.sh"
require_cluster
HOLD="${1:-240}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

open_ids() { bot_get '/incidents?status=open' | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(" ".join(i["id"] for i in d if i.get("service")=="activation"))' 2>/dev/null || true; }
inc_status() { bot_get "/incidents/$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo "?"; }
err_now() { promql '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])),0.001)' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}%'; }

step "Preconditions"
[[ -n "$(bot_get /healthz)" ]] || die "incident-bot not reachable — ./scripts/80-build-incident-bot.sh"
alertmanager_get /api/v2/status | grep -q incident-bot || die "Alertmanager is not routing to the bot — ./scripts/81-alertmanager-route.sh"
BEFORE="$(open_ids)"
[[ -z "$BEFORE" ]] && ok "no open activation incident" || warn "activation incident(s) already open: $BEFORE — the drill will attach to it"
ok "error rate now: $(err_now)"

step "Open these first"
say "  Overview     Grafana > Platform Overview  (incidents row at the bottom once you re-import)"
say "  Alertmanager kubectl port-forward svc/$(alertmanager_svc || echo '<alertmanager>') -n monitoring 9093:9093  -> http://localhost:9093"
say "  Bot          python3 tools/inc.py list     (run it whenever you like)"
echo
read -rp "Ready? Enter to break the fraud dependency. " _

step "Injecting FRAUD_SVC_DOWN=true"
T0=$(date +%s)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s

step "Waiting for the incident to OPEN (expect ~2.5 min; up to 6)"
ID=""
for i in $(seq 1 36); do
  sleep 10
  NOW="$(open_ids)"
  for cand in $NOW; do [[ " $BEFORE " == *" $cand "* ]] || ID="$cand"; done
  [[ -n "$ID" ]] && break
  printf '  t+%-4ss err=%-5s open=%s\n' "$(( $(date +%s) - T0 ))" "$(err_now)" "${NOW:-none}"
done
if [[ -z "$ID" ]]; then
  warn "no new incident after 6 minutes. Where did it stop?"
  printf '  Alertmanager sees for activation: '; alertmanager_get '/api/v2/alerts?active=true&filter=service%3Dactivation' | python3 "$LAB_ROOT/tools/amjson.py" names
  say "  If Alertmanager sees the alert but the bot has nothing: kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 | grep -i webhook"
  say "  If Alertmanager sees nothing: Prometheus > Alerts — is ActivationHighErrorRate firing?"
  exit 1
fi
ok "INCIDENT OPENED: $ID  (t+$(( $(date +%s) - T0 ))s after the fault)"
python3 "$LAB_ROOT/tools/inc.py" timeline "$ID"

REMAIN=$(( HOLD - ($(date +%s) - T0) ))
if (( REMAIN > 0 )); then
  step "Holding ${REMAIN}s more so the burn-rate alert joins the same incident"
  for ((i=30; i<=REMAIN; i+=30)); do sleep 30; printf '  t+%-4ss err=%-5s\n' "$(( $(date +%s) - T0 ))" "$(err_now)"; done
fi
say ""; say "  Alerts on the record now:"
bot_get "/incidents/$ID" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("   ", ", ".join(d.get("alerts",[])), "  severity:", d.get("severity"))'

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
TR=$(date +%s)

step "Waiting for the incident to RESOLVE (expect 5-8 min after recovery; up to 15)"
dim "Nothing to do here. This lag is the alert windows draining plus group_interval. Watch the"
dim "Alertmanager UI: the alerts go green one by one; the bot closes on the LAST one."
for i in $(seq 1 90); do
  sleep 10
  ST=$(inc_status "$ID")
  [[ "$ST" == "resolved" ]] && break
  (( i % 3 == 0 )) && printf '  +%-4ss after recovery  err=%-5s status=%s\n' "$(( $(date +%s) - TR ))" "$(err_now)" "$ST"
done
[[ "$ST" == "resolved" ]] || { warn "still open after 15 min. Alertmanager > which alert is still firing? BurnSlow (for: 15m) may have caught it — that is the 6h window; it resolves on its own."; exit 1; }
ok "INCIDENT RESOLVED: $ID  ($(( $(date +%s) - TR ))s after recovery)"
python3 "$LAB_ROOT/tools/inc.py" timeline "$ID"

step "The record"
say "  python3 tools/inc.py show $ID     # full JSON — this is what Day 9's AI reads"
say "  Note: first_alert_at is when Prometheus saw it; opened_at is when the ticket existed."
say "  The gap between them is group_wait + webhook latency. Time-to-detect is the fault"
say "  time (t+0 above) to first_alert_at — write both in incidents/INC-0007.md later."
echo
say "  Overview: 'Open incidents' went 0 -> 1 -> 0, 'Incidents (24h)' went up by one."
ok "Next: ./scripts/83-settlement-strict.sh"
