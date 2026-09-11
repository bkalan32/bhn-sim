#!/usr/bin/env bash
# Day 17, Step 7 — prove the difference: the fraud drill with the team's memory in the prompt.
# Same fault, same model, same prompt shape as Day 10 (INC-0009) and Day 16 (INC-0018);
# new: the KB block. The hypothesis should now cite kb-001, name which discriminating
# checks the context already confirms, and state the fix and tier as the team's prior
# answer. Logged as INC-0019 (the PDF says 0018 — CORRECTIONS-DAY17 N1).
#
#   ./scripts/173-kb-drill.sh [hold_seconds]    default 90 after the ticket opens
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
HOLD="${1:-90}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

step "Preconditions"
bot_get /ai | grep -c '"enabled": *true' >/dev/null || die "AI not enabled — ./scripts/90-ai-secret.sh"
bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin).get("kb") or {}; sys.exit(0 if d.get("ok") and d.get("entries") else 1)' \
  || die "the bot has no KB mounted (or is not the Day 17 build) — ./scripts/172-kb.sh --check"
ok "the bot sees $(bot_get /ai | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["kb"]["entries"]))') KB entries"
BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
"$LAB_ROOT/scripts/100-enrich-config.sh" --check || warn "a collector is degraded — the KB match still comes from alert names; the diagnosis should say which source is missing"
curl -fsS --max-time 2 http://localhost:30080/healthz >/dev/null 2>&1 || warn "no traffic on :30080 — is 12-loadgen.sh running? No traffic, no error rate, no alert"
say "  What the bot will match for this fault's words (before it happens):"
bot_get '/kb/search?q=activation+ActivationHighErrorRate+fraud_service_timeout' | python3 -c 'import json,sys; [print("    %s score %s  %s" % (h["id"], h["score"], h["title"])) for h in json.load(sys.stdin)]' 2>/dev/null || true
echo; read -rp "Ready? Enter to break the fraud dependency. " _

step "Injecting FRAUD_SVC_DOWN=true"
T0=$(date +%s); T0_ISO=$(date -u -d "@$T0" +%FT%TZ)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null

step "Waiting for the ticket (≈2.5 min)"
ID=$(wait_open "$BEFORE" 360) || die "no incident after 6 min — 82-incident-drill.sh's troubleshooting"
ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

step "Context, KB matches offered, and the diagnosis"
wait_field "$ID" ai_hypothesis 40 >/dev/null || true
say "  KB entries the bot put in the prompt (ai_meta.hypothesis.kb_matches):"
bot_get "/incidents/$ID" | python3 -c 'import json,sys; m=(json.load(sys.stdin).get("ai_meta") or {}).get("hypothesis") or {}; print("    " + (", ".join("%s (score %s)" % (x["id"], x["score"]) for x in m.get("kb_matches", [])) or "(none)"))'
show_context_and_hypothesis "$ID"
python3 "$INC" note "$ID" "drill: fault injected at $T0_ISO (FRAUD_SVC_DOWN=true) — Day 17, with the knowledge base in the prompt" >/dev/null
H=$(field "$ID" ai_hypothesis)
if grep -qi 'kb-001' <<<"$H"; then ok "the hypothesis cites kb-001"; else warn "the hypothesis does not cite kb-001 — read section 6; was the entry offered (kb_matches above)?"; fi
grep -qiE 'INC-000[18]|INC-0009' <<<"$H" && ok "…and the incidents it was learned from" || true
grep -qiE 'tier 3|no safe automated|escalat' <<<"$H" && ok "…and the team's prior answer (tier 3 / escalate)" || true
say "  Grade against INC-0009 (no KB) and INC-0018 (no KB, no logs): same model, same fault — docs/ai-eval.md Eval 8."
if (( HOLD > 0 )); then step "Holding ${HOLD}s"; for ((i=30;i<=HOLD;i+=30)); do sleep 30; printf '  err=%s\n' "$(err_now)"; done; fi

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
python3 "$INC" note "$ID" "drill: fault removed at $(date -u +%FT%TZ) (FRAUD_SVC_DOWN=false)" >/dev/null

step "Waiting for the ticket to resolve (3-8 min)"
wait_resolved "$ID" 900 || warn "still open after 15 min; the file below is written anyway"
ok "INCIDENT $(field "$ID" status): $ID"
wait_field "$ID" ai_resolution_draft 30 >/dev/null || true
write_diag_file "$ID" 0019 "The fraud drill with the knowledge base in the prompt (Day 17)"
say "  For docs/ops-kpis.md row 0019 and docs/ai-eval.md Eval 8: python3 tools/inc.py timeline $ID"
ok "Next: the copilot with search_kb — python3 tools/copilot.py -q \"what happened in $ID and does it match a known pattern?\""
