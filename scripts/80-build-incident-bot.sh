#!/usr/bin/env bash
# Day 8, Step 1 — build the incident bot, deploy it, and prove it works BEFORE
# Alertmanager is pointed at it. Debug one moving part at a time.
source "$(dirname "$0")/lib.sh"
require_docker; require_cluster

step "Unit tests first (the bot has tests — the PDF's does not)"
( cd "$LAB_ROOT/services/incident-bot" || exit 1
  [[ -d .venv ]] || python3 -m venv .venv
  # shellcheck disable=SC1091
  . .venv/bin/activate
  pip install -q -r requirements.txt -r requirements-dev.txt
  python -m pytest -q tests/ ) || die "tests failed — fix services/incident-bot before building"

step "Building incident-bot:0.1"
build_service incident-bot 0.1

step "Deploying (PVC + Deployment + Service + ServiceMonitor)"
k apply -f "$LAB_ROOT/k8s/incident-bot.yaml"
k rollout status deployment/incident-bot -n "$PAYMENTS_NS" --timeout=180s
PVC=$(k get pvc incident-bot-data -n "$PAYMENTS_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[[ "$PVC" == "Bound" ]] && ok "PVC incident-bot-data Bound (records survive restarts and deploys)" \
  || warn "PVC phase is '${PVC:-missing}' — kubectl describe pvc incident-bot-data -n payments"

step "Reaching it through the API server proxy (no port-forward)"
H=""
for _ in $(seq 1 12); do H=$(bot_get /healthz); [[ -n "$H" ]] && break; sleep 5; done
[[ -n "$H" ]] || die "bot not answering via proxy. kubectl logs -n payments deploy/incident-bot"
ok "healthz: $H"

step "Smoke test: a synthetic firing webhook, then a resolved one"
dim "tools/inc.py posts a payload in Alertmanager's exact shape with service=smoke-test."
python3 "$LAB_ROOT/tools/inc.py" webhook firing >/dev/null
sleep 1
python3 "$LAB_ROOT/tools/inc.py" list
ID=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')
[[ -n "$ID" ]] || die "no open incident after the firing webhook — kubectl logs -n payments deploy/incident-bot"
python3 "$LAB_ROOT/tools/inc.py" webhook resolved >/dev/null
sleep 1
python3 "$LAB_ROOT/tools/inc.py" timeline "$ID"
ST=$(bot_get "/incidents/$ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
[[ "$ST" == "resolved" ]] && ok "opened -> resolved, duration filled in" || die "incident did not resolve (status=$ST)"
python3 "$LAB_ROOT/tools/inc.py" delete "$ID" >/dev/null && ok "smoke-test record deleted"

step "Is Prometheus scraping it?"
V="no data"
for _ in $(seq 1 8); do
  V=$(promql 'incidents_open' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
  [[ "$V" != "no data" ]] && break; sleep 10
done
[[ "$V" != "no data" ]] && ok "incidents_open = $V in Prometheus" \
  || warn "incidents_open not scraped yet. ServiceMonitor label release=kps? Prometheus > Status > Targets"

echo
say "The bot works end to end with a hand-made webhook. Now the real source:"
ok "Next: ./scripts/81-alertmanager-route.sh"
