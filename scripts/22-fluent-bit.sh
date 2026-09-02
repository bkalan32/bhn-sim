#!/usr/bin/env bash
# Day 3, Step 4 — ship container logs to Splunk with Fluent Bit.
#
# Usage:  ./scripts/22-fluent-bit.sh <HEC-TOKEN>
#
# FIX vs the PDF: the PDF has you paste a hardcoded IP (172.18.0.5) into the values
# file. Docker reassigns container IPs on restart, so that file goes stale the first
# time you reboot — and the symptom is "no data in Splunk" with nothing in any log
# that says why. This renders the values file from the live IP every time.

source "$(dirname "$0")/lib.sh"
require_docker
require_cluster

TOKEN="${1:-${SPLUNK_HEC_TOKEN:-}}"
[[ -n "$TOKEN" ]] || die "No HEC token.
       Usage: ./scripts/22-fluent-bit.sh <TOKEN>
       Get one in Splunk: Settings > Data Inputs > HTTP Event Collector > New Token"

step "Locating Splunk on the kind network"
IP="$(splunk_ip || true)"
[[ -n "$IP" ]] || die "Splunk is not on the 'kind' Docker network.
       Is the container running?  docker ps --filter name=splunk
       Was it started with --network kind?  ./scripts/21-splunk-up.sh"
ok "Splunk at ${IP}:8088"

step "Testing the HEC endpoint before installing anything"
# Splunk's HEC listener defaults to SSL ON in the container image, and it only binds
# port 8088 at all once HEC is globally enabled. So probe both schemes and report what
# we actually found, instead of assuming plain HTTP the way the PDF does.
probe() {  # $1 = scheme ; always echoes something, always exits 0
  local out
  # `|| true` is load-bearing: curl exits non-zero when it cannot connect, and under
  # `set -e` a failing command substitution kills the whole script AT THE ASSIGNMENT,
  # before any of the error handling below can run. You get a blank prompt instead of
  # a message. This is the third time this pattern has bitten this repo -- if you take
  # one shell lesson from the series, take this one.
  out=$(docker run --rm --network kind curlimages/curl:latest \
        -sk -o /dev/null -w '%{http_code}' --max-time 8 \
        "$1://${IP}:8088/services/collector/event" \
        -H "Authorization: Splunk ${TOKEN}" \
        -d '{"event":"bhn-sim hec preflight","sourcetype":"manual"}' 2>/dev/null || true)
  printf '%s' "${out:-000}"
  return 0
}

SCHEME=""
for s in http https; do
  CODE="$(probe "$s" || true)"
  printf '  %-5s -> HTTP %s\n' "$s" "${CODE:-000}"
  if [[ "$CODE" == "200" ]]; then SCHEME="$s"; break; fi
  # A 4xx means we REACHED Splunk on this scheme; the problem is the token, not TLS.
  if [[ "$CODE" == "403" || "$CODE" == "401" ]]; then
    die "HTTP $CODE on $s — Splunk answered, but rejected the token.
       Either the token value is wrong, or All Tokens is disabled.
       Splunk: Settings > Data Inputs > HTTP Event Collector > Global Settings
               > All Tokens = Enabled"
  fi
  if [[ "$CODE" == "400" ]]; then
    die "HTTP 400 on $s — token accepted but the event was rejected.
       Usually the token's Allowed Indexes does not include 'main'.
       Splunk: Settings > Data Inputs > HTTP Event Collector > (your token) > Edit"
  fi
done

if [[ -z "$SCHEME" ]]; then
  die "No response on either http or https at ${IP}:8088.
       Nothing is listening, which almost always means HEC is not enabled yet.
         1. Splunk > Settings > Data Inputs > HTTP Event Collector
         2. Global Settings > All Tokens = Enabled  (and untick Enable SSL) > Save
         3. Confirm from your shell:
              curl -s  -o /dev/null -w '%{http_code}\n' http://localhost:8088/services/collector/health
              curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8088/services/collector/health
       If Splunk is still booting, wait for 'Ansible playbook complete' first:
              docker logs splunk | tail -5"
fi

if [[ "$SCHEME" == "https" ]]; then
  TLS_SETTING="On"
  ok "HEC accepted a test event over HTTPS"
  dim "SSL is enabled on your HEC listener, so Fluent Bit is configured with TLS On."
else
  TLS_SETTING="Off"
  ok "HEC accepted a test event over HTTP"
fi
dim "Search 'index=main bhn-sim' in Splunk — that preflight event should be there."

step "Rendering k8s/fluent-bit-values.yaml from the template"
sed -e "s|__SPLUNK_IP__|${IP}|" -e "s|__SPLUNK_TOKEN__|${TOKEN}|" -e "s|__TLS__|${TLS_SETTING}|" \
  "$LAB_ROOT/k8s/fluent-bit-values.yaml.tmpl" > "$LAB_ROOT/k8s/fluent-bit-values.yaml"
chmod 600 "$LAB_ROOT/k8s/fluent-bit-values.yaml"
ok "rendered (contains your token — .gitignore already excludes it)"
dim "Tailing ONLY /var/log/containers/*_payments_*.log, not the whole cluster."
dim "500 MB/day on trial AND free; the whole cluster would burn that in about a day."

step "Installing Fluent Bit"
helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update fluent >/dev/null
helm upgrade --install fluent-bit fluent/fluent-bit \
  --kube-context "$KUBE_CONTEXT" \
  -n "$LOGGING_NS" --create-namespace \
  -f "$LAB_ROOT/k8s/fluent-bit-values.yaml" \
  --wait --timeout 5m

step "Fluent Bit status"
k get pods -n "$LOGGING_NS"
sleep 10
step "Fluent Bit's own logs (looking for HTTP errors)"
if k logs -n "$LOGGING_NS" -l app.kubernetes.io/name=fluent-bit --tail=30 2>/dev/null | grep -iE 'error|warn|403|refused'; then
  warn "Errors above. 403 = bad token or All Tokens disabled. Connection refused = wrong IP or HEC off."
else
  ok "no errors in Fluent Bit's log"
fi

step "Now search in Splunk"
say "  index=main app.service=activation"
dim "Give it 60 seconds. Then work through splunk/searches.md."
ok "Next: ./scripts/23-alerts.sh"
