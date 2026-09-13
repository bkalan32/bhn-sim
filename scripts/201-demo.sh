#!/usr/bin/env bash
# Day 20, Step 3 — the 15-minute demo, driven and timed. docs/demo.md is the script you read
# aloud; this file runs the commands in the same order, prints the clock at every step, waits
# for Enter between them, and writes checkpoints/day20-demo.txt with the total when it ends.
#
#   ./scripts/201-demo.sh            the tour (kind; up.sh + both load generators first)
#   ./scripts/201-demo.sh --check    preconditions only
#
# The fault is the fraud dependency (kb-001), injected by this script (173 prompts and writes INC-0019 files —
# not for a demo): injected at ~minute 1,
# alert at ~4, ticket +15 s, hypothesis +30 s, copilot at ~6, reverted at ~7, resolved at ~12,
# the brief at ~13. Talk over the waits — they are the point (the alert windows are real).
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
T0=$(date +%s); clock() { printf '%02d:%02d' $(( ($(date +%s) - T0) / 60 )) $(( ($(date +%s) - T0) % 60 )); }
beat() { step "[$(clock)] $*"; }
pause() { dim "  (Enter to continue)"; read -r </dev/tty; }
DAY="$(date -u +%F)-demo"
INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-demo — reverting FRAUD_SVC_DOWN=false"; k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

step "Preconditions — a demo on a broken platform demonstrates the wrong thing"
n=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
[[ "$n" == 0 ]] && ok "no open incidents" || die "$n open incident(s) — python3 tools/inc.py list open"
"$LAB_ROOT/scripts/100-enrich-config.sh" --check >/dev/null 2>&1 && ok "three collectors ok" || die "a collector is down — ./scripts/100-enrich-config.sh --check (Splunk still booting? docs/morning.md)"
KBN=$(bot_get /ai | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("kb",{}).get("entries",[])))' 2>/dev/null || echo 0)
(( KBN >= 7 )) && ok "the bot has the KB ($KBN entries)" || die "no KB on the bot — ./scripts/172-kb.sh"
A=$(promql 'sum(rate(activation_requests_total[2m]))' | python3 tools/promjson.py value '{:.1f}' 2>/dev/null || echo 0)
[[ "$A" != "no data" && "$A" != "0.0" ]] && ok "activation traffic $A req/s" || die "no traffic — terminal 2: ./scripts/12-loadgen.sh (and 3: 33-loadgen-egift.sh)"
E=$(promql 'sum(rate(egift_orders_total[2m]))' | python3 tools/promjson.py value '{:.1f}' 2>/dev/null || echo 0)
[[ "$E" != "no data" && "$E" != "0.0" ]] && ok "egift traffic $E orders/s" || warn "no egift traffic — ./scripts/33-loadgen-egift.sh (the copilot's 'is egift affected?' needs it)"
RS=$(rem_get /healthz | python3 -c 'import json,sys; d=json.load(sys.stdin); print("dry-run" if d.get("dry_run") else "live")' 2>/dev/null || echo down)
[[ "$RS" == live ]] && ok "remediator live" || warn "remediator is $RS"
AIP=$(bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("provider") or d.get("mode") or "?")' 2>/dev/null || echo '?')
[[ "$AIP" == anthropic || "$AIP" == ollama ]] && ok "AI drafts: $AIP" || die "AI drafts: $AIP — ./scripts/90-ai-secret.sh"
[[ "${1:-}" == --check ]] && exit 0
say "  Grafana on :3000 → Platform Overview on the screen you are sharing. Then Enter starts the clock."
pause; T0=$(date +%s)

beat "1 · The platform in one screen (talk: three services, the overview, the seven KPIs)"
python3 tools/inc.py list open
python3 tools/kpis.py --summary --days 30 | head -12
pause

beat "2 · Break it — the fraud dependency goes down (the same fault as INC-0001/0009/0018/0019: FRAUD_SVC_DOWN=true)"
T_INJ=$(date -u +%FT%TZ)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true >/dev/null && INJECTED=1 && ok "injected at $T_INJ"
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
say "  Talk while it lands: the overview's health row sags first; the alert needs ~3 minutes of a 2-minute error-rate window."
say "  Splunk on the other tab: index=main app.service=activation app.status=error | stats count by app.reason"
for _ in $(seq 1 40); do
  ID=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; l=json.load(sys.stdin); print(l[0]["id"] if l else "")' 2>/dev/null)
  [[ -n "$ID" ]] && break; sleep 10; printf '  [%s] err=%s\n' "$(clock)" "$(promql '100*sum(rate(activation_requests_total{status="error"}[2m]))/sum(rate(activation_requests_total[2m]))' | python3 tools/promjson.py value '{:.0f}%' 2>/dev/null)"
done
[[ -n "$ID" ]] || die "no ticket after 6+ minutes — is the load generator running? (kubectl -n payments get deploy activation -o yaml | grep FRAUD)"
python3 tools/inc.py note "$ID" "demo: fault injected at $T_INJ (FRAUD_SVC_DOWN=true) — Day 20 rehearsal" >/dev/null 2>&1 || true
beat "3 · The page: ticket $ID opened by the platform"
python3 tools/inc.py timeline "$ID" | head -8
pause

beat "4 · What the ticket already knows — three sources, attached before anyone looked"
python3 tools/inc.py context "$ID" | head -14
pause
beat "5 · The hypothesis — the team's memory in the prompt (it should cite kb-001 by id, and say tier 3)"
for _ in $(seq 1 12); do python3 tools/inc.py hypothesis "$ID" 2>/dev/null | grep -q 'MOST LIKELY' && break; sleep 5; done
python3 tools/inc.py hypothesis "$ID" | sed -n '/MOST LIKELY/,/ALTERNATIVE/p;/KNOWLEDGE BASE/,$p' | head -30
pause

beat "6 · The copilot — one question, read-only hands, every step a tool result"
python3 tools/copilot.py --tag demo -q "activation errors are up and the logs say fraud_service_timeout — what is this, and is egift affected?" | tail -25
pause

beat "7 · The remediator — what it did, and why nothing (tier 3: external dependency)"
python3 tools/rem.py actions | head -4
say "  Now the 'vendor fixes it': FRAUD_SVC_DOWN=false. Nothing else is done by hand; the alert clears on its 5-minute window."
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null && INJECTED=0 && ok "reverted at $(date -u +%FT%TZ)"
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
python3 tools/inc.py note "$ID" "demo: fault removed at $(date -u +%FT%TZ) (FRAUD_SVC_DOWN=false)" >/dev/null 2>&1 || true
pause

beat "8 · Resolution — by the platform, with the resolution draft (talk: the KB entry this feeds)"
for _ in $(seq 1 48); do
  ST=$(bot_get "/incidents/$ID" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)
  [[ "$ST" == resolved ]] && break; sleep 10
done
python3 tools/inc.py timeline "$ID" | tail -4
[[ "$ST" == resolved ]] && python3 tools/inc.py drafts "$ID" | sed -n '/RESOLVED DRAFT/,$p' | head -16 || warn "not resolved yet — the windows; keep talking (kb/fraud-dependency-outage.md on screen)"
pause

beat "9 · Tomorrow morning, today — the daily brief reads the record it just made"
python3 tools/daily_report.py --day "$DAY" | tail -10
pause

beat "10 · Close — the record is the product"
python3 tools/kpis.py --summary --days 1 | sed -n '3,6p'
say "  incidents/ · kb/ · docs/ai-eval.md — the write-ups are where the judgment is."
TOTAL=$(( ($(date +%s) - T0) / 60 ))
printf 'demo rehearsed %s: %s min, ticket %s, brief reports/daily/%s.md\n' "$(date -u +%FT%TZ)" "$TOTAL" "$ID" "$DAY" > checkpoints/day20-demo.txt
ok "DEMO: $TOTAL minutes ($(cat checkpoints/day20-demo.txt | cut -d, -f2-))"
(( TOTAL <= 16 )) && ok "inside the 15-minute promise" || warn "over 15 — cut the pauses you did not need (the waits are fixed: ~3 min to the alert, ~5 to resolve)"
