#!/usr/bin/env bash
# Day 9, Step 3 — prove the AI path in one minute, before spending ten on a drill.
# A synthetic incident (service=smoke-test) opens, the bot drafts in the background,
# we wait for the draft, resolve it, wait for the resolution draft, print both, delete.
source "$(dirname "$0")/lib.sh"
require_cluster
INC="$LAB_ROOT/tools/inc.py"

step "Which build, which provider?"
IMG=$(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
say "  image=$IMG"
[[ "$IMG" == "incident-bot:0.1" ]] && die "still 0.1 — ship 0.2 first: Jenkins SERVICE=incident-bot, or locally ./scripts/80-build-incident-bot.sh"
AI=$(bot_get /ai); say "  $AI"
echo "$AI" | grep -q '"enabled": *true' || die "no AI provider configured — ./scripts/90-ai-secret.sh"

field() { bot_get "/incidents/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(v if v else "")' "$2" 2>/dev/null || true; }
wait_draft() {  # id field seconds
  local v
  for _ in $(seq 1 "$3"); do v=$(field "$1" "$2"); [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }; sleep 2; done
  return 1
}

step "Synthetic incident opens"
python3 "$INC" webhook firing >/dev/null
ID=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; d=[i for i in json.load(sys.stdin) if i.get("service")=="smoke-test"]; print(d[0]["id"] if d else "")')
[[ -n "$ID" ]] || die "no smoke-test incident opened"
ok "$ID"

step "Waiting for ai_open_draft (background thread; typically 5-20s)"
if D=$(wait_draft "$ID" ai_open_draft 45); then
  echo; printf '%s\n' "$D" | sed 's/^/  │ /'; echo
  [[ "$D" == "(AI draft unavailable"* ]] && warn "the call FAILED — read the reason above. 401 = key; 404 = model name; URLError = network" || ok "open draft attached"
else
  die "no draft after 90s. kubectl logs -n payments deploy/incident-bot | python3 tools/logfmt.py"
fi

step "Resolving it"
python3 "$INC" webhook resolved >/dev/null
if D=$(wait_draft "$ID" ai_resolution_draft 45); then
  echo; printf '%s\n' "$D" | sed 's/^/  │ /'; echo
  ok "resolution draft attached"
fi

step "Cost and latency of those two calls"
bot_get "/incidents/$ID" | python3 -c 'import json,sys
m=json.load(sys.stdin).get("ai_meta",{})
for k,v in m.items():
    print("  %-9s %s/%s  %s ms  in=%s out=%s  ok=%s" % (k, v.get("provider"), v.get("model"), v.get("latency_ms"), v.get("input_tokens"), v.get("output_tokens"), v.get("ok")))'
python3 "$INC" delete "$ID" >/dev/null && ok "smoke record deleted"
echo
say "Read the drafts like an engineer. The record had ONE alert named SmokeTest with a"
say "one-line summary and no runbook. Did the model stay inside that? 'not yet known' where"
say "it should be? Anything invented — a cause, a number, a customer impact it could not know?"
ok "Next: ./scripts/92-ai-drill.sh"
