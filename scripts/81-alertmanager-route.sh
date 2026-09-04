#!/usr/bin/env bash
# Day 8, Step 2 — point Alertmanager at the bot, the Helm way, and PROVE the config
# landed. "helm upgrade said OK" is not proof; Alertmanager's own status page is.
source "$(dirname "$0")/lib.sh"
require_cluster
have helm || die "helm not found"

step "Loading the new rules first (egift latency/error alerts, IncidentBotDown)"
k apply -f "$LAB_ROOT/k8s/alerts.yaml"
ok "k8s/alerts.yaml applied — backlog #3 (EgiftHighLatency) is now a rule, not a wish"

step "Which chart version is installed?"
# FIX vs the PDF: `helm upgrade` without --version takes the newest chart in your repo
# cache. After a `helm repo update` that can be a major version bump — new CRDs, new
# defaults — smuggled in under a routing change. Pin to what is running.
VER=$(helm list --kube-context "$KUBE_CONTEXT" -n "$MONITORING_NS" -o json 2>/dev/null \
      | python3 -c 'import json,sys; d=[x for x in json.load(sys.stdin) if x["name"]=="'"$HELM_RELEASE"'"]; print(d[0]["chart"].rsplit("-",1)[1] if d else "")' 2>/dev/null || true)
[[ -n "$VER" ]] || die "release '$HELM_RELEASE' not found in $MONITORING_NS"
ok "kube-prometheus-stack $VER"

step "helm upgrade with k8s/kps-values.yaml (pinned to $VER, --reuse-values)"
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$LAB_ROOT/k8s/kps-values.yaml" 2>/dev/null \
  || warn "PyYAML not available to pre-check the file; helm will validate it"
helm upgrade "$HELM_RELEASE" prometheus-community/kube-prometheus-stack \
  --kube-context "$KUBE_CONTEXT" -n "$MONITORING_NS" \
  --version "$VER" --reuse-values -f "$LAB_ROOT/k8s/kps-values.yaml" \
  --wait --timeout 10m
ok "upgrade applied"

step "1/3  Did the generated secret change?"
SEC=$(k get secret -n "$MONITORING_NS" -o name | sed 's|secret/||' | grep -E '^alertmanager-.*-generated$' | head -1 || true)
[[ -n "$SEC" ]] || die "no alertmanager-*-generated secret in $MONITORING_NS"
if k get secret "$SEC" -n "$MONITORING_NS" -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | grep -q 'incident-bot.payments:8020'; then
  ok "$SEC contains the incident-bot webhook"
else
  die "the generated config does NOT mention incident-bot. Values file indentation is the usual cause:
       helm get values $HELM_RELEASE -n $MONITORING_NS   # should show alertmanager.config.route..."
fi

step "2/3  Did Alertmanager reload it? (config-reloader polls; up to ~2 min)"
LOADED=0
for _ in $(seq 1 24); do
  if alertmanager_get /api/v2/status | grep -q 'incident-bot'; then LOADED=1; break; fi
  sleep 5
done
(( LOADED )) && ok "Alertmanager's live config has the incident-bot receiver" \
  || die "Alertmanager has not reloaded after 2 min: kubectl logs -n monitoring alertmanager-${HELM_RELEASE}-kube-prometheus-stack-alertmanager-0 -c config-reloader"

step "3/3  Which alerts are currently firing, and where do they route?"
alertmanager_get '/api/v2/alerts?active=true' | python3 "$LAB_ROOT/tools/amjson.py" routing

step "Did anything reach the bot already?"
dim "If an alert with a service label was firing during the upgrade (EgiftHighLatency is a"
dim "candidate — Day 7's screenshot had eGift p95 at 2.4s), the bot will have an incident now."
python3 "$LAB_ROOT/tools/inc.py" list
echo
ok "Next: ./scripts/82-incident-drill.sh"
