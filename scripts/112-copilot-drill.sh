#!/usr/bin/env bash
# Day 11, Step 4 — interrogate a BROKEN platform. The fraud dependency goes down (the
# same fault as Days 3, 8, 9 and 10), and this time the copilot runs the Day 3 diagnostic
# loop itself: error rate -> top error reasons -> rollout history -> answer with numbers.
# Logged as INC-0011 (the PDF says INC-0010; ours is one higher — CORRECTIONS-DAY11 N1).
#
# Timing, on purpose: the questions run ~90 s after the fault, BEFORE the ticket opens
# (~2.5 min). If the ticket existed, get_incident would hand the model the bot's
# enrichment context and the "investigation" would be reading a ticket. Here it has to
# look things up. The ticket then opens during/after the questions and gets the usual
# drill note — after its own hypothesis, as on Day 10.
#
# Usage: ./scripts/112-copilot-drill.sh [lead_seconds]   (default 90: how long the fault
#        runs before the questions start)
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
LEAD="${1:-90}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

step "Preconditions"
bot_get /openapi.json | grep -q '/tools/search_logs' || die "bot is not 0.4 — ship it first (Jenkins SERVICE=incident-bot)"
BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
python3 tools/copilot.py --selftest >/dev/null 2>&1 || die "copilot self-test failed — ./scripts/110-copilot-preflight.sh"
ok "bot 0.4, no open activation incident, tools healthy"
echo; read -rp "Ready? Enter to break the fraud dependency. " _

step "Injecting FRAUD_SVC_DOWN=true"
T0=$(date +%s); T0_ISO=$(date -u -d "@$T0" +%FT%TZ)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null

step "Letting the fault show in the 5-minute windows (${LEAD}s)"
for ((i=15;i<=LEAD;i+=15)); do sleep 15; printf '  t+%-4ss err(1m)=%s\n' "$(( $(date +%s) - T0 ))" "$(err_now)"; done

step "The copilot investigates (docs/copilot-questions/broken.txt)"
say "  Watch the [tool] lines. A good run: error rate -> top app.reason -> rollout history/deploys -> answer."
echo
python3 tools/copilot.py -f docs/copilot-questions/broken.txt --tag drill-fraud-INC-0011 || warn "copilot exited non-zero"
TRANSCRIPT=$(ls -t docs/copilot-transcripts/*drill-fraud-INC-0011.md 2>/dev/null | head -1)

step "The ticket (it should have opened while the copilot was talking)"
ID=$(wait_open "$BEFORE" 300) || die "no incident after 5 more minutes — 82-incident-drill.sh's troubleshooting"
ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"
wait_field "$ID" ai_hypothesis 60 >/dev/null || true
python3 "$INC" note "$ID" "drill: fault injected at $T0_ISO (FRAUD_SVC_DOWN=true); copilot transcript ${TRANSCRIPT:-n/a}" >/dev/null
say "  Bot's own diagnosis, for comparison with the copilot's (same fault, two paths):"
h=$(field "$ID" ai_hypothesis); [[ -n "$h" ]] && { echo; box "$h" | head -40; echo; }

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
python3 "$INC" note "$ID" "drill: fault removed at $(date -u +%FT%TZ) (FRAUD_SVC_DOWN=false)" >/dev/null

step "Waiting for the ticket to resolve (3-8 min)"
wait_resolved "$ID" 900 || warn "still open after 15 min"
ok "INCIDENT $(field "$ID" status): $ID"
echo
ok "Transcript: ${TRANSCRIPT:-docs/copilot-transcripts/}"
say "  Grade it in docs/ai-eval.md Eval 4 (tool trail, cause, numbers cited) and write incidents/INC-0011.md."
ok "Next: ./scripts/113-copilot-adversarial.sh"
