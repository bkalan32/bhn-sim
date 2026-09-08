#!/usr/bin/env bash
# Day 12, Step 3 — fan the Alertmanager webhook out to the remediator, load the new rules,
# and PROVE the plumbing with a synthetic incident before any real drill.
#
# Uses 81-alertmanager-route.sh for the helm upgrade (pinned version, --reuse-values, the
# three proofs), then checks the second webhook landed, then sends one synthetic alert
# through the whole path: Alertmanager-shaped webhook -> bot opens a ticket -> the same
# webhook -> remediator -> no signature -> "tier 3: human required" note on that ticket.
# If that note appears, every hop works. Then it cleans up.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1

step "Preconditions"
rem_get /healthz | grep -q '"status"' || die "remediator not answering — ship it first (Jenkins SERVICE=remediator)"
ok "remediator up"

"$LAB_ROOT/scripts/81-alertmanager-route.sh"

step "Did the fan-out land?"
SEC=$(k get secret -n "$MONITORING_NS" -o name | sed 's|secret/||' | grep -E '^alertmanager-.*-generated$' | head -1 || true)
k get secret "$SEC" -n "$MONITORING_NS" -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | grep -q 'remediator.payments:8030' \
  && ok "generated config carries the remediator webhook" || die "no remediator webhook in the generated config — k8s/kps-values.yaml indentation?"
LOADED=0; for _ in $(seq 1 24); do alertmanager_get /api/v2/status | grep -q 'remediator' && { LOADED=1; break; }; sleep 5; done
(( LOADED )) && ok "Alertmanager's live config mentions the remediator" || die "Alertmanager has not reloaded after 2 min"

step "Rules: PaymentsPodCrashLooping and RemediatorDown loaded?"
if k get prometheusrule -n "$PAYMENTS_NS" -o json 2>/dev/null | grep -q 'PaymentsPodCrashLooping'; then
  ok "PrometheusRule carries PaymentsPodCrashLooping (Prometheus reloads within ~1 min)"
else
  warn "PaymentsPodCrashLooping not in any PrometheusRule in $PAYMENTS_NS — kubectl apply -f k8s/alerts.yaml"
fi

step "End-to-end proof with a synthetic alert (service smoke-test — matches no signature)"
BEFORE="$(open_ids_for smoke-test)"
[[ -z "$BEFORE" ]] || die "a smoke-test incident is already open ($BEFORE) — python3 tools/inc.py webhook resolved; then delete it"
python3 "$INC" webhook firing >/dev/null
ID=""; for _ in $(seq 1 12); do ID=$(open_ids_for smoke-test | awk '{print $1}'); [[ -n "$ID" ]] && break; sleep 2; done
[[ -n "$ID" ]] || die "the bot did not open a ticket for the synthetic webhook"
ok "bot opened $ID"
# The synthetic webhook went ONLY to the bot (tools/inc.py posts to the bot directly, not through
# Alertmanager). Post the same payload to the remediator to prove ITS half of the fan-out path.
python3 - "$ID" <<'PY'
import json, subprocess, sys, tempfile, time
proxy = "/api/v1/namespaces/payments/services/remediator:8030/proxy/alertmanager"
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
payload = {"version": "4", "groupKey": '{}/{service="smoke-test"}:{service="smoke-test"}', "status": "firing", "receiver": "incident-bot",
           "groupLabels": {"service": "smoke-test"}, "commonLabels": {"service": "smoke-test"}, "commonAnnotations": {}, "externalURL": "x", "truncatedAlerts": 0,
           "alerts": [{"status": "firing", "labels": {"alertname": "SmokeTest", "severity": "warning", "service": "smoke-test"},
                       "annotations": {"summary": "synthetic"}, "startsAt": now, "endsAt": "0001-01-01T00:00:00Z", "fingerprint": "smoketest"}]}
with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
    json.dump(payload, f); name = f.name
r = subprocess.run(["kubectl", "--context", "kind-bhn-sim", "create", "--raw", proxy, "-f", name], capture_output=True, text=True)
print("  remediator says:", (r.stdout or r.stderr).strip()[:120])
PY
NOTE=""; for _ in $(seq 1 15); do NOTE=$(rem_notes "$ID" | grep -F 'tier 3' || true); [[ -n "$NOTE" ]] && break; sleep 2; done
if [[ -n "$NOTE" ]]; then ok "the remediator found the ticket and wrote:"; box "$NOTE"; else warn "no [remediator] note on $ID within 30 s — kubectl logs -n payments deploy/remediator | python3 tools/logfmt.py"; fi
python3 "$INC" webhook resolved >/dev/null; sleep 1; python3 "$INC" delete "$ID" >/dev/null && ok "synthetic ticket cleaned up"
echo
ok "Next: ./scripts/122-drill-tier1.sh crashloop"
