#!/usr/bin/env bash
# Day 10, Step 1 — give the bot read access to Grafana and Splunk, the right way.
#
#   ./scripts/100-enrich-config.sh          create/refresh secret/enrich-config, restart the bot, test all 3 collectors
#   ./scripts/100-enrich-config.sh --check  just test the collectors (what would the bot see right now?)
#
# Two credentials the PDF hardcodes in source, handled properly here:
#   Grafana   a SERVICE ACCOUNT with the Viewer role and a token, created through the API.
#             Not the admin password in a base64 header in enrich.py. Survives password
#             rotation; can be revoked without touching anything else.
#   Splunk    the REST API (port 8089) authenticates with the ADMIN LOGIN, not the HEC
#             token — different port, different credential, a classic confusion. Splunk is
#             a plain container on the kind network; its IP moves on every restart (Day 3),
#             so the address is rendered into the secret and up.sh warns when it drifts.
source "$(dirname "$0")/lib.sh"
require_cluster
SECRET=enrich-config

test_collectors() {
  step "What the collectors see right now (via the bot)"
  local out
  out=$(bot_get '/enrich/test?service=activation')
  [[ -n "$out" ]] || { warn "bot not answering /enrich/test — is 0.3 deployed?"; return 1; }
  printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin); c = d["collectors"]; ctx = d["context"]
def line(name, m, sample):
    st = "ok" if m.get("ok") else "FAIL"
    print("  %-8s %-5s %5s ms   %s" % (name, st, m.get("latency_ms"), sample if m.get("ok") else m.get("error")))
m = ctx.get("metrics") or {}
line("metrics", c["metrics"], "error_rate=%s%%  p95=%ss  req/s=%s  health=%s" % (m.get("error_rate_pct"), m.get("p95_latency_s"), m.get("req_per_s"), m.get("health_score")))
dep = ctx.get("recent_deploys") or []
line("deploys", c["deploys"], ("%d entries; newest: %s (%s min ago)" % (len(dep), dep[0].get("text"), dep[0].get("minutes_before_first_alert"))) if dep and "text" in dep[0] else (dep[0].get("note") if dep else "none"))
rs = ctx.get("top_error_reasons") or []
line("logs", c["logs"], ", ".join("%s=%s" % (r.get("reason"), r.get("count")) for r in rs if "reason" in r) or (rs[0].get("note") if rs else "none"))
bad = [k for k, v in c.items() if not v.get("ok")]
sys.exit(1 if bad else 0)'
}

if [[ "${1:-}" == "--check" ]]; then test_collectors && ok "all three collectors healthy" || warn "a collector is degraded — the bot still works; the diagnosis will say so"; exit 0; fi

step "Grafana: service account + token (Viewer)"
GPW=$(k get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' | base64 -d)
gcurl() { k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- curl -sf -u "admin:$GPW" -H 'Content-Type: application/json' "$@"; }
# idempotent: find or create the SA, then mint a fresh token (old ones stay valid; revoke in the UI if you care)
SA_ID=$(gcurl 'http://localhost:3000/api/serviceaccounts/search?query=incident-bot' | python3 -c 'import json,sys; d=json.load(sys.stdin); h=[s for s in d.get("serviceAccounts",[]) if s["name"]=="incident-bot"]; print(h[0]["id"] if h else "")' 2>/dev/null || true)
if [[ -z "$SA_ID" ]]; then
  SA_ID=$(gcurl -X POST http://localhost:3000/api/serviceaccounts -d '{"name":"incident-bot","role":"Viewer"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  ok "service account 'incident-bot' created (id $SA_ID, role Viewer)"
else
  ok "service account 'incident-bot' exists (id $SA_ID)"
fi
GTOKEN=$(gcurl -X POST "http://localhost:3000/api/serviceaccounts/$SA_ID/tokens" -d "{\"name\":\"enrich-$(date +%s)\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
[[ -n "$GTOKEN" ]] || die "could not mint a Grafana token"
ok "token minted (not shown)"

step "Splunk: management endpoint"
SIP=$(splunk_ip)
[[ -n "$SIP" ]] || die "splunk container not running (docker start splunk)"
SURL="https://${SIP}:8089"
# The decisive test runs from INSIDE the cluster (below, via the bot): the kind node sits
# on the same Docker network as Splunk, your WSL shell does not, and 8089 is not
# published to the host. A probe from here is informational only.
CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 -u "admin:${SPLUNK_PASSWORD}" "$SURL/services/server/info?output_mode=json" 2>/dev/null || true); CODE="${CODE:-000}"
case "$CODE" in
  200) ok "$SURL answers with the admin login from WSL too (HTTP 200)" ;;
  401) die "Splunk REST at $SURL says HTTP 401 — wrong admin password (SPLUNK_PASSWORD env, default Changeme123!)" ;;
  *)   dim "WSL cannot reach $SURL directly (HTTP $CODE) — expected on Docker Desktop; the in-cluster check below is the real one" ;;
esac

step "Storing secret/$SECRET"
k create secret generic "$SECRET" -n "$PAYMENTS_NS" \
  --from-literal=GRAFANA_TOKEN="$GTOKEN" \
  --from-literal=SPLUNK_URL="$SURL" \
  --from-literal=SPLUNK_USER=admin \
  --from-literal=SPLUNK_PASSWORD="$SPLUNK_PASSWORD" \
  --from-literal=SPLUNK_VERIFY=false \
  --dry-run=client -o yaml | k apply -f - >/dev/null
unset GTOKEN
ok "stored: GRAFANA_TOKEN, SPLUNK_URL=$SURL, SPLUNK_USER, SPLUNK_PASSWORD, SPLUNK_VERIFY=false"
dim "SPLUNK_VERIFY=false accepts Splunk's self-signed certificate. Lab only; flagged in the README."

if k get deploy incident-bot -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  step "Restarting the bot to pick up the secret"
  k rollout restart deployment/incident-bot -n "$PAYMENTS_NS" >/dev/null
  k rollout status deployment/incident-bot -n "$PAYMENTS_NS" --timeout=120s >/dev/null && ok "restarted"
  sleep 3
  if bot_get /ai | grep -q '"enrich"'; then
    if test_collectors; then ok "all three collectors healthy"
    else
      warn "a collector is degraded — see above."
      say "  logs 'HTTP 401'      -> wrong Splunk admin password: SPLUNK_PASSWORD=... $0"
      say "  logs 'URLError'      -> the pod cannot reach $SURL: is Splunk running on the kind network? docker inspect splunk | grep -A3 '\"kind\"'"
      say "  deploys 'HTTP 401'   -> token problem; re-run $0"
      say "  Or continue: the diagnosis names the missing source and lowers its confidence."
    fi
  else
    warn "the running bot is not 0.3 yet — ship it (Jenkins SERVICE=incident-bot) and then: $0 --check"
  fi
fi
ok "Next: ./scripts/102-drill-a.sh"
