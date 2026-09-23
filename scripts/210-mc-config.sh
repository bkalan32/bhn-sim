#!/usr/bin/env bash
# Day 21, Steps 3-4 — Mission Control's secrets, its read-only RBAC outside payments, and the
# proof that its permissions are what the design says.
#
#   ./scripts/210-mc-config.sh            mint the bearer token (if none), ask for a Jenkins API token,
#                                         apply k8s/mission-control-rbac.yaml, then --check
#   ./scripts/210-mc-config.sh --check    the RBAC proof only (asked of the API server), no changes
#   ./scripts/210-mc-config.sh --rotate   mint a NEW bearer token (the old one stops working on restart)
#
# The bearer token: 32 random bytes -> secret/mission-control-auth (MC_TOKEN) and ONE local copy at
# ~/.bhn-sim/mc-token (chmod 600, outside the repo) so tools/mc.py and your browser can use it.
# Never printed. The Jenkins token is an API TOKEN (Jenkins > your name > Security > API Token >
# Add new token), not your password — revocable on its own, and it needs no CSRF crumb.
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
SA="system:serviceaccount:${PAYMENTS_NS}:mission-control"
LOCAL="$HOME/.bhn-sim/mc-token"

proof() {
  step "RBAC — what may mission-control do? (the API server answers)"
  local fail=0
  chk() { local want=$1; shift; local got; got=$(k auth can-i "$@" --as="$SA" 2>/dev/null || true)
          [[ "$got" == "$want" ]] && ok "$got  $*" || { warn "$got  $*   (expected $want)"; fail=1; }; }
  say "  what the catalog needs:"
  chk yes patch deployments/activation -n "$PAYMENTS_NS"
  chk yes patch deployments/loadgen -n "$PAYMENTS_NS"
  chk yes patch deployments/egift --subresource=scale -n "$PAYMENTS_NS"
  chk yes create jobs -n "$PAYMENTS_NS"
  chk yes delete pods -n "$PAYMENTS_NS"
  chk yes patch cronjobs/settlement -n "$PAYMENTS_NS"
  chk yes get configmaps/kb -n "$PAYMENTS_NS"
  chk yes list pods -n "$MONITORING_NS"
  chk yes list deployments -n tracing
  say "  and the boundary:"
  chk no delete deployments -n "$PAYMENTS_NS"
  chk no get secrets -n "$PAYMENTS_NS"
  chk no create pods -n "$PAYMENTS_NS"
  chk no patch cronjobs/other -n "$PAYMENTS_NS"
  chk no get configmaps/anything-else -n "$PAYMENTS_NS"
  chk no delete pods -n "$MONITORING_NS"
  chk no patch deployments -n "$MONITORING_NS"
  chk no get secrets -n "$MONITORING_NS"
  chk no list nodes
  (( fail == 0 )) && ok "RBAC holds" || die "RBAC does not match the design — fix k8s/mission-control*.yaml before the drills"
}

if [[ "${1:-}" == "--check" ]]; then proof; exit 0; fi

step "1/4  Read-only RBAC in monitoring / tracing / logging"
k apply -f k8s/mission-control-rbac.yaml >/dev/null && ok "k8s/mission-control-rbac.yaml applied"
k get sa mission-control -n "$PAYMENTS_NS" >/dev/null 2>&1 \
  || warn "ServiceAccount mission-control not there yet — it ships with the service (Jenkins deploy-service SERVICE=mission-control). Re-run --check after."

step "2/4  The bearer token"
mkdir -p "$(dirname "$LOCAL")"; chmod 700 "$(dirname "$LOCAL")"
if [[ "${1:-}" != "--rotate" ]] && k get secret mission-control-auth -n "$PAYMENTS_NS" >/dev/null 2>&1 && [[ -s "$LOCAL" ]]; then
  ok "secret/mission-control-auth exists and ~/.bhn-sim/mc-token is there (--rotate to replace)"
else
  TOK=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
  k create secret generic mission-control-auth -n "$PAYMENTS_NS" --from-literal=MC_TOKEN="$TOK" --dry-run=client -o yaml | k apply -f - >/dev/null
  ( umask 077; printf '%s' "$TOK" > "$LOCAL" )
  unset TOK
  ok "secret/mission-control-auth + ~/.bhn-sim/mc-token (600) — not shown"
  k get deploy mission-control -n "$PAYMENTS_NS" >/dev/null 2>&1 && { k rollout restart deploy/mission-control -n "$PAYMENTS_NS" >/dev/null; ok "restarted mission-control to read it"; }
fi

step "3/4  Jenkins (for run_drift_check, generate_report, deploy)"
JIP=$(timeout 15 docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' jenkins 2>/dev/null || true)
[[ -n "$JIP" ]] || die "no Jenkins IP on the kind network — is the jenkins container running? (docker ps)"
say "  Jenkins at http://$JIP:8080 on the kind network (pods cannot resolve Docker container names)."
if k get secret mission-control-config -n "$PAYMENTS_NS" >/dev/null 2>&1 && [[ "${1:-}" != "--jenkins" ]]; then
  CUR=$(k get secret mission-control-config -n "$PAYMENTS_NS" -o jsonpath='{.data.JENKINS_URL}' | base64 -d)
  if [[ "$CUR" == "http://$JIP:8080" ]]; then ok "secret/mission-control-config exists, Jenkins URL current (--jenkins to re-enter the token)"
  else
    k get secret mission-control-config -n "$PAYMENTS_NS" -o json \
      | python3 -c "import json,sys,base64; d=json.load(sys.stdin); d['data']['JENKINS_URL']=base64.b64encode(b'http://$JIP:8080').decode(); [d['metadata'].pop(k,None) for k in ('resourceVersion','uid','creationTimestamp','managedFields','annotations')]; print(json.dumps(d))" \
      | k apply -f - >/dev/null
    ok "Jenkins moved ($CUR -> http://$JIP:8080) — URL updated, token kept"
  fi
else
  say "  Jenkins > (your name, top right) > Security > API Token > Add new token > name it mission-control > copy"
  read -rp  "  Jenkins username [admin]: " JU; JU="${JU:-admin}"
  read -rsp "  Jenkins API token (not shown): " JT; echo
  [[ -n "$JT" ]] || die "no token entered"
  # the credentials go to curl on stdin (-K -), not on a command line where `ps` would show them
  CODE=$(printf 'user = "%s:%s"\n' "$JU" "$JT" | docker run --rm -i --network kind curlimages/curl:latest -K - -s -o /dev/null -w '%{http_code}' "http://$JIP:8080/api/json" 2>/dev/null || echo 000)
  [[ "$CODE" == 200 ]] || die "Jenkins answered HTTP $CODE to that user/token (401 = wrong token; 000 = not reachable on the kind network)"
  ok "Jenkins accepts the token (HTTP 200 from inside the kind network)"
  k create secret generic mission-control-config -n "$PAYMENTS_NS" --from-literal=JENKINS_URL="http://$JIP:8080" \
    --from-literal=JENKINS_USER="$JU" --from-literal=JENKINS_TOKEN="$JT" --dry-run=client -o yaml | k apply -f - >/dev/null
  unset JT
  ok "secret/mission-control-config"
  k get deploy mission-control -n "$PAYMENTS_NS" >/dev/null 2>&1 && { k rollout restart deploy/mission-control -n "$PAYMENTS_NS" >/dev/null; ok "restarted mission-control to read it"; }
fi

step "4/4  Proof"
k get sa mission-control -n "$PAYMENTS_NS" >/dev/null 2>&1 && proof || warn "skipped: deploy mission-control first, then $0 --check"
ok "Next: kubectl -n $PAYMENTS_NS port-forward svc/mission-control 8040:8040   then   python3 tools/mc.py overview"
