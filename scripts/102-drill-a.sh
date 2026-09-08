#!/usr/bin/env bash
# Day 10, Drill A — dependency outage. The fifth run of this fault, and the first time the
# ticket arrives with the three lookups already done and a diagnosis attached.
#
# Expect in the context: error rate near 100, p95 near 0.3s (Day 7's fail-fast at work),
# fraud_service_timeout as the only reason, NO recent deploy. Expect the hypothesis to
# name the fraud dependency with high confidence and suggest checks like the ones you
# actually ran on Day 3. Logged as INC-0009.
#
# Usage: ./scripts/102-drill-a.sh [hold_seconds]   (default 120 after the ticket opens)
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
HOLD="${1:-120}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

step "Preconditions"
bot_get /ai | grep -q '"enabled": *true' || die "AI not enabled — ./scripts/90-ai-secret.sh"
bot_get /ai | grep -q '"enrich"' || die "bot is not 0.3 — ship it first (Jenkins SERVICE=incident-bot)"
BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
"$LAB_ROOT/scripts/100-enrich-config.sh" --check || warn "continuing with a degraded collector — the diagnosis should say so; that is part of the test"
echo; read -rp "Ready? Enter to break the fraud dependency. " _

step "Injecting FRAUD_SVC_DOWN=true"
T0=$(date +%s); T0_ISO=$(date -u -d "@$T0" +%FT%TZ)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null

step "Waiting for the ticket (≈2.5 min)"
ID=$(wait_open "$BEFORE" 360) || die "no incident after 6 min — 82-incident-drill.sh's troubleshooting"
ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

step "Waiting for context + diagnosis (enrichment ~5-30s, then two AI calls)"
wait_field "$ID" ai_hypothesis 40 >/dev/null || true
show_context_and_hypothesis "$ID"
# The fault time goes on the record for the KPI table — but only AFTER the diagnosis, and
# tagged "drill:" so ai.py hides it from the model. The first Drill A posted it before,
# and the model "diagnosed" from the answer key. Ground truth never goes in the input.
python3 "$INC" note "$ID" "drill: fault injected at $T0_ISO (FRAUD_SVC_DOWN=true)" >/dev/null

say "  Grade it now, while the outage is live — is the cause right? Is the confidence honest?"
say "  Do the suggested checks look like what you ran on Day 3?"
if (( HOLD > 0 )); then step "Holding ${HOLD}s"; for ((i=30;i<=HOLD;i+=30)); do sleep 30; printf '  err=%s\n' "$(err_now)"; done; fi

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
python3 "$INC" note "$ID" "drill: fault removed at $(date -u +%FT%TZ) (FRAUD_SVC_DOWN=false)" >/dev/null

step "Waiting for the ticket to resolve (3-8 min)"
wait_resolved "$ID" 900 || { warn "still open after 15 min; the file below is written anyway"; }
ok "INCIDENT $(field "$ID" status): $ID"
wait_field "$ID" ai_resolution_draft 30 >/dev/null || true
write_diag_file "$ID" 0009 "Drill A: dependency outage, enriched"
echo
say "  Compare with Drill B when you have it: same alert name, different context, different diagnosis."
ok "Next: ./scripts/103-drill-b.sh apply"
