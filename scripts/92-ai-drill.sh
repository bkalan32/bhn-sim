#!/usr/bin/env bash
# Day 9, Steps 4-5 — the real drill, with you as the responder.
#
# Same fraud outage as Days 3 and 8. New today:
#   * the bot drafts the internal summary + stakeholder update when the ticket OPENS
#   * you post what you observe and do, as notes, DURING the incident (the scribe role)
#   * the bot drafts the resolution note + close-out + review skeleton when it RESOLVES,
#     and the skeleton's Root cause / Timeline come from YOUR notes
# Then it writes everything to incidents/INC-0008-ai-drafts.md for grading.
#
# Usage: ./scripts/92-ai-drill.sh [hold_seconds]   (default 180)
source "$(dirname "$0")/lib.sh"
require_cluster
INC="$LAB_ROOT/tools/inc.py"
HOLD="${1:-180}"; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "exiting mid-drill — reverting FRAUD_SVC_DOWN=false"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM

field() { bot_get "/incidents/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(v if v else "")' "$2" 2>/dev/null || true; }
open_ids() { bot_get '/incidents?status=open' | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(" ".join(i["id"] for i in d if i.get("service")=="activation"))' 2>/dev/null || true; }
err_now() { promql '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])),0.001)' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}%'; }
box() { printf '%s\n' "$1" | sed 's/^/  │ /'; }
wait_field() { local v; for _ in $(seq 1 "$3"); do v=$(field "$1" "$2"); [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }; sleep 3; done; return 1; }

step "Preconditions"
bot_get /ai | grep -q '"enabled": *true' || die "AI not enabled on the bot — ./scripts/90-ai-secret.sh"
IMG=$(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}')
[[ "$IMG" != "incident-bot:0.1" ]] || die "bot is still 0.1"
BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "an activation incident is already open ($BEFORE) — wait for it to close"
ok "bot $IMG, AI on, error rate $(err_now)"
echo
say "  You are the responder on this one. When the ticket opens, read the AI's first draft,"
say "  then investigate as you did on Day 3 (Splunk: index=main app.service=activation"
say "  app.status=error | stats count by app.reason) and POST WHAT YOU FIND as notes."
say "  The script offers the two canned notes from the guide; typing your own is better."
echo
read -rp "Ready? Enter to break the fraud dependency. " _

step "Injecting FRAUD_SVC_DOWN=true"
T0=$(date +%s)
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=true; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null

step "Waiting for the ticket (≈2.5 min)"
ID=""
for _ in $(seq 1 36); do
  sleep 10; NOW="$(open_ids)"; [[ -n "$NOW" ]] && { ID="${NOW%% *}"; break; }
  printf '  t+%-4ss err=%s\n' "$(( $(date +%s) - T0 ))" "$(err_now)"
done
[[ -n "$ID" ]] || die "no incident after 6 min — see 82-incident-drill.sh's troubleshooting"
ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

step "The AI's opening draft (background; usually 5-20s)"
if D=$(wait_field "$ID" ai_open_draft 30); then echo; box "$D"; echo; else warn "no open draft yet — continuing; check later with: python3 tools/inc.py drafts $ID"; fi
say "  Read it against the record: python3 tools/inc.py timeline $ID"
say "  Every time and alert name it quotes should be there. Any cause it names is INVENTED —"
say "  the record does not contain one yet."
echo

step "Scribe: post what you observe (during the outage)"
say "  Option A — your own words, in another terminal:"
say "    python3 tools/inc.py note $ID \"...what Splunk shows...\""
say "  Option B — Enter here posts the guide's first note."
read -rp "  Enter to post: 'Splunk shows reason=fraud_service_timeout on 100% of errors. Suspect fraud dependency.' (or type your own, then Enter): " TXT
TXT="${TXT:-Splunk shows reason=fraud_service_timeout on 100% of errors. Suspect fraud dependency.}"
python3 "$INC" note "$ID" "$TXT" >/dev/null && ok "note posted"

REMAIN=$(( HOLD - ($(date +%s) - T0) ))
if (( REMAIN > 0 )); then step "Holding ${REMAIN}s more"; for ((i=30;i<=REMAIN;i+=30)); do sleep 30; printf '  t+%-4ss err=%s\n' "$(( $(date +%s) - T0 ))" "$(err_now)"; done; fi

step "Recovering: FRAUD_SVC_DOWN=false"
k set env deployment/activation -n "$PAYMENTS_NS" FRAUD_SVC_DOWN=false; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s >/dev/null
TR=$(date +%s)
read -rp "  Enter to post: 'Restored fraud service config. Error rate recovering.' (or your own): " TXT2
TXT2="${TXT2:-Restored fraud service config. Error rate recovering.}"
python3 "$INC" note "$ID" "$TXT2" >/dev/null && ok "note posted"

step "Waiting for the ticket to resolve (3-8 min)"
for i in $(seq 1 90); do
  sleep 10; ST=$(field "$ID" status)
  [[ "$ST" == "resolved" ]] && break
  (( i % 3 == 0 )) && printf '  +%-4ss err=%-5s status=%s\n' "$(( $(date +%s) - TR ))" "$(err_now)" "$ST"
done
[[ "$ST" == "resolved" ]] || { warn "still open after 15 min; the resolution draft will attach when it closes: python3 tools/inc.py drafts $ID"; exit 1; }
ok "INCIDENT RESOLVED: $ID ($(( $(date +%s) - TR ))s after recovery)"

step "The AI's resolution draft — Root cause and Timeline should now come from YOUR notes"
if D=$(wait_field "$ID" ai_resolution_draft 30); then echo; box "$D"; echo; else warn "no resolution draft yet: python3 tools/inc.py drafts $ID"; fi

step "Writing incidents/INC-0008-ai-drafts.md"
OUT="$LAB_ROOT/incidents/INC-0008-ai-drafts.md"
{
  echo "# INC-0008 — AI drafts (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo; echo "Record: \`$ID\` · fault injected t+0 = $(date -u -d "@$T0" +%H:%M:%SZ) · recovered $(date -u -d "@$TR" +%H:%M:%SZ)"
  echo; echo "## Timeline (the ground truth every claim below is graded against)"; echo; echo '```'
  python3 "$INC" timeline "$ID"; echo '```'
  echo; echo "## ai_open_draft"; echo; echo '```'; field "$ID" ai_open_draft; echo '```'
  echo; echo "## ai_resolution_draft"; echo; echo '```'; field "$ID" ai_resolution_draft; echo '```'
  echo; echo "## Meta"; echo; echo '```'
  bot_get "/incidents/$ID" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("ai_meta",{}), indent=2))'
  echo '```'
} > "$OUT"
ok "$OUT"
echo
say "Now GRADE them — docs/ai-eval.md has the rubric. Check every number, every time, every"
say "claim against the timeline above. Then compare with the no-notes drafts on the Day 8"
say "record (python3 tools/inc.py draft <day-8 id> resolved) — that contrast is the lesson."
ok "Next: ./scripts/93-ai-resilience.sh"
