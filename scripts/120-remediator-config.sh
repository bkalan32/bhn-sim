#!/usr/bin/env bash
# Day 12, Step 2 — the remediator's two credentials, and the proof that RBAC holds.
#
#   ./scripts/120-remediator-config.sh          mint a Grafana EDITOR token for annotations -> secret/remediator-config;
#                                               prove the ServiceAccount's Role does exactly what the policy says
#   ./scripts/120-remediator-config.sh --check  the RBAC proof only
#
# Two credentials, two shapes:
#   Kubernetes   the pod's ServiceAccount token, mounted automatically. Its Role
#                (k8s/remediator.yaml) is the safety: three actions, one namespace, one
#                deployment. `kubectl auth can-i --as=` asks the API server what that
#                identity may do — the answer is the API server's, not our belief.
#   Grafana      an Editor service-account token so a remediator rollback is annotated the
#                way a pipeline rollback is (the Day 10 deploy collector reads annotations).
#                Viewer (Day 10's token) cannot write annotations; admin would be too much.
source "$(dirname "$0")/lib.sh"
require_cluster
SA="system:serviceaccount:${PAYMENTS_NS}:remediator"

rbac_proof() {
  step "RBAC: what may $SA do? (asked of the API server)"
  local fail=0
  chk() {  # expect verb resource [extra...]
    local expect="$1"; shift
    local got; got=$(k auth can-i "$@" -n "$PAYMENTS_NS" --as="$SA" 2>/dev/null || true)
    if [[ "$got" == "$expect" ]]; then ok "$(printf '%-3s %s' "$got" "$*")"; else warn "$(printf '%-3s %s   (expected %s)' "$got" "$*" "$expect")"; fail=1; fi
  }
  say "  the three actions:"
  chk yes delete pods
  chk yes create jobs
  chk yes get cronjobs/settlement
  chk yes patch deployments/activation
  chk yes list replicasets
  say "  and the boundary:"
  chk no get secrets
  chk no list secrets
  chk no delete deployments
  chk no patch deployments/egift
  chk no patch deployments/incident-bot
  chk no delete jobs
  chk no create pods
  chk no get configmaps
  k auth can-i delete pods -n monitoring --as="$SA" 2>/dev/null | grep -qx no && ok "no  delete pods in monitoring (namespace-scoped)" || { warn "yes delete pods in monitoring — the Role leaked out of payments"; fail=1; }
  k auth can-i get nodes --as="$SA" 2>/dev/null | grep -qx no && ok "no  get nodes (cluster-wide)" || { warn "yes get nodes"; fail=1; }
  return $fail
}

if [[ "${1:-}" == "--check" ]]; then
  k get sa remediator -n "$PAYMENTS_NS" >/dev/null 2>&1 || die "no ServiceAccount remediator — kubectl apply -f k8s/remediator.yaml (or the Jenkins build)"
  rbac_proof && ok "RBAC holds" || die "RBAC does not match the policy — fix k8s/remediator.yaml before the drills"
  exit 0
fi

step "Grafana: service account 'remediator' (Editor) + token"
GPW=$(k get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' | base64 -d)
gcurl() { k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- curl -sf -u "admin:$GPW" -H 'Content-Type: application/json' "$@"; }
SA_ID=$(gcurl 'http://localhost:3000/api/serviceaccounts/search?query=remediator' | python3 -c 'import json,sys; d=json.load(sys.stdin); h=[s for s in d.get("serviceAccounts",[]) if s["name"]=="remediator"]; print(h[0]["id"] if h else "")' 2>/dev/null || true)
if [[ -z "$SA_ID" ]]; then
  SA_ID=$(gcurl -X POST http://localhost:3000/api/serviceaccounts -d '{"name":"remediator","role":"Editor"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  ok "service account 'remediator' created (id $SA_ID, role Editor — annotations need write)"
else
  ok "service account 'remediator' exists (id $SA_ID)"
fi
GTOKEN=$(gcurl -X POST "http://localhost:3000/api/serviceaccounts/$SA_ID/tokens" -d "{\"name\":\"remediator-$(date +%s)\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
[[ -n "$GTOKEN" ]] || die "could not mint a Grafana token"
ok "token minted (not shown)"

step "Storing secret/remediator-config"
k create secret generic remediator-config -n "$PAYMENTS_NS" --from-literal=GRAFANA_TOKEN="$GTOKEN" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
unset GTOKEN
ok "stored: GRAFANA_TOKEN"

if k get deploy remediator -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  step "Restarting the remediator to pick up the secret"
  k rollout restart deployment/remediator -n "$PAYMENTS_NS" >/dev/null
  k rollout status deployment/remediator -n "$PAYMENTS_NS" --timeout=120s >/dev/null && ok "restarted"
  sleep 2
  rem_get /signatures | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  dry_run=%s  grafana_annotations=%s  signatures=%s" % (d["dry_run"], d["grafana_annotations"], ", ".join(s["id"]+"(t%d)"%s["tier"] for s in d["signatures"])))' 2>/dev/null || warn "remediator not answering yet"
  rbac_proof && ok "RBAC holds" || die "RBAC does not match the policy"
else
  warn "remediator not deployed yet — ship it (Jenkins SERVICE=remediator), then: $0 --check"
fi
ok "Next: ./scripts/121-remediator-route.sh"
