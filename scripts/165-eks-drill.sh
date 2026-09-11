#!/usr/bin/env bash
# Day 16, Step 3c — the Day 10 dependency-outage drill, on a cloud the platform has never
# seen. Same fault (FRAUD_SVC_DOWN=true), same alert rules, same bot, same remediator
# policy, same AI — the only thing that changed is where it runs. Logged as INC-0018
# (the PDF says 0017; that number was Day 14's second fault — CORRECTIONS-DAY16 N1).
#
# What to grade: does the ticket open in the same ~2.5 min? Is the context the same shape
# minus the logs collector (Splunk is on the laptop; CloudWatch holds the logs and the bot
# has no collector for it yet — that gap is deliberate and the record should SAY so)?
# Does the hypothesis still name the dependency, with lower confidence because one source
# is missing? Did the remediator (tier 3 for this signature) stay out of it?
#
#   ./scripts/165-eks-drill.sh [hold_seconds]     default 120 after the ticket opens
export KUBE_CONTEXT=aws-lab
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
HOLD="${1:-120}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

step "Preconditions (context $KUBE_CONTEXT — say it out loud: this is the CLOUD cluster)"
kubectl --context "$KUBE_CONTEXT" get nodes --no-headers | awk '{print "  node " $1 " " $2}'
bot_get /ai | grep -c '"enabled": *true' >/dev/null || die "AI not enabled on the EKS bot — 163 copies secret/ai-keys from kind; or KUBE_CONTEXT=aws-lab ./scripts/90-ai-secret.sh"
BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
"$LAB_ROOT/scripts/100-enrich-config.sh" --check || true
curl -fsS --max-time 2 http://localhost:18000/healthz >/dev/null 2>&1 || warn "no traffic path on :18000 — is ./scripts/164-eks-traffic.sh running? Without traffic there is no error RATE, so no alert"
echo; read -rp "Ready? Enter to break the fraud dependency on EKS. " _

step "Injecting FRAUD_SVC_DOWN=true (aws-lab)"
T0=$(date +%s); T0_ISO=$(date -u -d "@$T0" +%FT%TZ)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null

step "Waiting for the ticket (≈2.5 min — the same rules, the same for: windows)"
ID=$(wait_open "$BEFORE" 360) || die "no incident after 6 min — is 164 running? kubectl --context aws-lab -n payments logs deploy/incident-bot | tail"
ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

step "Context + diagnosis"
wait_field "$ID" ai_hypothesis 40 >/dev/null || true
show_context_and_hypothesis "$ID"
python3 "$INC" note "$ID" "drill: fault injected at $T0_ISO (FRAUD_SVC_DOWN=true) — on EKS ($(kubectl --context "$KUBE_CONTEXT" get nodes --no-headers | wc -l) spot nodes, $AWS_REGION); zero application or manifest changes" >/dev/null

say "  Grade it against INC-0009 (the same drill on kind): same cause named? Confidence lower because"
say "  the logs source is 'not configured'? Does the context say WHY it is missing?"
if (( HOLD > 0 )); then step "Holding ${HOLD}s"; for ((i=30;i<=HOLD;i+=30)); do sleep 30; printf '  err=%s\n' "$(err_now)"; done; fi

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
python3 "$INC" note "$ID" "drill: fault removed at $(date -u +%FT%TZ) (FRAUD_SVC_DOWN=false)" >/dev/null

step "Waiting for the ticket to resolve (3-8 min)"
wait_resolved "$ID" 900 || warn "still open after 15 min; the file below is written anyway"
ok "INCIDENT $(field "$ID" status): $ID"
wait_field "$ID" ai_resolution_draft 30 >/dev/null || true
write_diag_file "$ID" 0018 "EKS: the Day 10 dependency drill on a cloud the platform had never seen"

step "The same incident, in CloudWatch (the second pane of glass — eks-notes #3)"
Q=$(aws logs start-query --log-group-name /bhn-sim/containers --start-time "$((T0-60))" --end-time "$(date +%s)" \
     --query-string 'fields @timestamp, app.service, app.status, app.reason | filter app.service = "activation" and app.status = "error" | stats count() by app.reason' \
     --query queryId --output text 2>/dev/null || true)
if [[ -n "$Q" ]]; then
  sleep 6
  aws logs get-query-results --query-id "$Q" --query 'results[].[ [0].value, [1].value ]' --output text 2>/dev/null | awk '{printf "  %-32s %s\n",$1,$2}'
  say "  (Logs Insights, the query that works: app.* fields — the PDF's \`filter log like /activation failed/\` matches nothing: B6)"
else
  warn "Logs Insights query did not start — is /bhn-sim/containers there? aws logs describe-log-groups --log-group-name-prefix /bhn-sim"
fi
echo
say "  For docs/ops-kpis.md row 0018 and docs/ai-eval.md Eval 7: python3 tools/inc.py timeline $ID"
ok "Next: ./scripts/166-eks-differences.sh"
