#!/usr/bin/env bash
# Day 17, Part A — the New Relic license key, into Secrets and nowhere else.
#
#   ./scripts/170-newrelic-secret.sh            prompt for the INGEST - LICENSE key (not echoed), store it, verify
#   ./scripts/170-newrelic-secret.sh --check    is it there, in both namespaces?
#   ./scripts/170-newrelic-secret.sh --remove   delete both copies (the agents stop shipping; nothing else breaks)
#
# Where to get it: one.newrelic.com -> your name (bottom left) -> API keys -> the key of type
# INGEST - LICENSE (40 chars, ends in NRAL). Not a USER key, not the browser key.
# Two copies of one secret: the `newrelic` namespace for the agents (the chart reads it by
# name — global.customSecretName), and `monitoring` for Prometheus's remote write (the
# operator can only mount Secrets in its own namespace). Same rule as Day 9 / Day 13: the
# key touches no file in this repo, no shell history (read -s), no Terraform state.
source "$(dirname "$0")/lib.sh"
require_cluster
NR_NS=newrelic; SECRET=newrelic-license

case "${1:-}" in
  --check)
    for ns in "$NR_NS" "$MONITORING_NS"; do
      if k get secret "$SECRET" -n "$ns" >/dev/null 2>&1; then
        L=$(k get secret "$SECRET" -n "$ns" -o jsonpath='{.data.license}' | base64 -d | wc -c)
        ok "secret/$SECRET in $ns ($L chars$( (( L == 40 )) && echo ", the expected length" || echo " — a license key is 40 chars; is this the right key type?"))"
      else warn "secret/$SECRET missing in $ns"; fi
    done; exit 0 ;;
  --remove)
    for ns in "$NR_NS" "$MONITORING_NS"; do k delete secret "$SECRET" -n "$ns" --ignore-not-found >/dev/null && ok "removed from $ns"; done
    dim "  Terraform still expects the release; ./infra/local/tf.sh plan will show the agents failing on the next refresh — remove the release from releases.tf if you mean to leave."
    exit 0 ;;
esac

step "New Relic INGEST - LICENSE key"
say "  one.newrelic.com -> (your name, bottom left) -> API keys -> type 'INGEST - LICENSE' -> copy"
read -rsp "  Paste the key (not shown): " KEY; echo
KEY="${KEY//[[:space:]]/}"
[[ ${#KEY} -eq 40 && "$KEY" == *NRAL ]] || { warn "that is ${#KEY} chars and does not end in NRAL — a license key is 40 chars ending NRAL. A USER key (NRAK-…) will not work for ingest."; read -rp "  Store it anyway? [y/N] " a; [[ "$a" == y ]] || die "not stored"; }

# The namespace is Terraform's (infra/local/namespaces.tf); 171 creates it first with a
# targeted apply. Making it here with kubectl would hand Terraform an "already exists".
k get ns "$NR_NS" >/dev/null 2>&1 || die "namespace $NR_NS does not exist yet — ./scripts/171-newrelic-up.sh creates it (Terraform) and calls this script"
for ns in "$NR_NS" "$MONITORING_NS"; do
  k create secret generic "$SECRET" -n "$ns" --from-literal=license="$KEY" --dry-run=client -o yaml | k apply -f - >/dev/null
  ok "secret/$SECRET in $ns (key: license)"
done
unset KEY

step "Does the key work? (one small POST to the Metric API — what remote write will do every 30 s)"
# A single synthetic metric to the same endpoint Prometheus will use. 202 = accepted.
CODE=$(k get secret "$SECRET" -n "$MONITORING_NS" -o jsonpath='{.data.license}' | base64 -d | {
  read -r key
  curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST https://metric-api.newrelic.com/metric/v1 \
    -H "Content-Type: application/json" -H "Api-Key: $key" \
    -d '[{"metrics":[{"name":"bhn_sim.day17.smoke","type":"gauge","value":1,"timestamp":'"$(date +%s)"',"attributes":{"source":"170-newrelic-secret.sh"}}]}]'
} 2>/dev/null || echo 000)
case "$CODE" in
  202) ok "Metric API accepted a test point (HTTP 202) — the key is a working ingest key" ;;
  403) die "HTTP 403 — not an ingest key (a USER key, or the wrong account): re-run with the INGEST - LICENSE key" ;;
  *)   warn "Metric API answered HTTP $CODE — network or key; the in-cluster proof is 171's remote-write counters" ;;
esac
ok "Next: ./scripts/171-newrelic-up.sh"
