#!/usr/bin/env bash
# Day 9, exit criterion — "the system kept working with the API key removed".
#
# Takes the provider away (AI_PROVIDER=none: same effect as deleting the key, without
# making you retype it afterwards), opens and resolves a synthetic incident, proves the
# record is complete and says WHY there is no draft, then puts the provider back.
source "$(dirname "$0")/lib.sh"
require_cluster
INC="$LAB_ROOT/tools/inc.py"
restore() { k set env deployment/incident-bot -n "$PAYMENTS_NS" AI_PROVIDER=auto >/dev/null 2>&1 || true; }
trap restore EXIT

step "Before: provider"
python3 "$INC" ai | sed 's/^/  /'

step "Taking the AI away (AI_PROVIDER=none, pod restarts)"
k set env deployment/incident-bot -n "$PAYMENTS_NS" AI_PROVIDER=none >/dev/null
k rollout status deployment/incident-bot -n "$PAYMENTS_NS" --timeout=120s >/dev/null
for _ in $(seq 1 12); do bot_get /ai | grep -q '"enabled": *false' && break; sleep 5; done
bot_get /ai | grep -q '"enabled": *false' && ok "bot up, AI disabled" || die "bot did not come back with AI disabled"

step "Synthetic incident, open -> resolve, with no AI"
python3 "$INC" webhook firing >/dev/null
ID=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; d=[i for i in json.load(sys.stdin) if i.get("service")=="smoke-test"]; print(d[0]["id"] if d else "")')
[[ -n "$ID" ]] || die "incident did not open without AI — THAT would be the real failure"
python3 "$INC" webhook resolved >/dev/null
sleep 1
bot_get "/incidents/$ID" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert d["status"]=="resolved" and d.get("duration_min") is not None, d
print("  status=%s duration=%s min" % (d["status"], d["duration_min"]))
print("  ai_open_draft:       ", d.get("ai_open_draft"))
print("  ai_resolution_draft: ", d.get("ai_resolution_draft"))
assert str(d.get("ai_open_draft","")).startswith("(AI draft unavailable"), "draft should say why it is missing"' \
  && ok "record complete; drafts say why they are missing" || die "record incomplete without AI"
python3 "$INC" delete "$ID" >/dev/null

step "Putting the AI back (AI_PROVIDER=auto)"
restore; trap - EXIT
k rollout status deployment/incident-bot -n "$PAYMENTS_NS" --timeout=120s >/dev/null
for _ in $(seq 1 12); do bot_get /ai | grep -q '"enabled": *true' && break; sleep 5; done
python3 "$INC" ai | sed 's/^/  /'
echo
say "  The try/except in the PDF is 'the most important line of AI engineering in the file'."
say "  Ours is a provider switch plus a background thread plus this test — same principle:"
say "  the incident system must never fail because the AI failed."
ok "Next: grade docs/ai-eval.md, write INC-0008.md, then ./scripts/98-checkpoint-day9.sh"
