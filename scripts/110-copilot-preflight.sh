#!/usr/bin/env bash
# Day 11, Step 2 — prove the copilot's HANDS before you trust its brain.
#
# Every tool is exercised once with no model in the loop: Prometheus through the API
# server proxy, the bot's read-only search endpoint (bot 0.4), kubectl with the allow-list
# (including two calls that MUST be refused), the incident records, and the API key read
# from secret/ai-keys. A copilot whose tools are broken produces confident answers about
# nothing — "not available" is only honest when the tool actually tried.
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1

step "Bot version"
V=$(bot_get /healthz | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
IMG=$(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if bot_get /openapi.json | grep -q '/tools/search_logs'; then
  ok "incident-bot answers /tools/search_logs (version $V, image $IMG)"
else
  die "the running bot ($IMG, version $V) has no /tools/search_logs — ship 0.4 first:
       git add -A && git commit -m 'Day 11: incident-bot 0.4' && Jenkins SERVICE=incident-bot"
fi

step "AI key"
k get secret ai-keys -n "$PAYMENTS_NS" >/dev/null 2>&1 && ok "secret/ai-keys present (the copilot reads it through your kubeconfig)" \
  || die "no secret/ai-keys — ./scripts/90-ai-secret.sh"

step "Splunk collector (the search tool depends on it)"
"$LAB_ROOT/scripts/100-enrich-config.sh" --check >/dev/null 2>&1 && ok "all three collectors healthy" \
  || warn "a collector is degraded — ./scripts/100-enrich-config.sh --check. search_logs will report the error as a tool result; that is a valid thing to grade, not a blocker"

step "Every tool once, no model"
python3 tools/copilot.py --selftest || die "a tool failed its self-test — fix it before asking the model anything"

echo
ok "Next: python3 tools/copilot.py -f docs/copilot-questions/warmup.txt --tag warmup"
dim "  (or interactive: python3 tools/copilot.py)"
