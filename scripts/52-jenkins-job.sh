#!/usr/bin/env bash
# Day 6, Step 4 — create the deploy-service pipeline job via the Jenkins API.
# Usage: JENKINS_USER=admin JENKINS_PASS=... ./scripts/52-jenkins-job.sh
source "$(dirname "$0")/lib.sh"
U="${JENKINS_USER:-admin}"; P="${JENKINS_PASS:-}"
[[ -n "$P" ]] || { read -rsp "Jenkins password for $U: " P; echo; }
J=http://localhost:8081
step "Crumb"
CRUMB=$(curl -fsS -u "$U:$P" "$J/crumbIssuer/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])' 2>/dev/null || true)
[[ -n "$CRUMB" ]] || die "could not authenticate to Jenkins as $U. Create the job in the UI instead (see DAY6.md Step 4)."
step "Creating job deploy-service"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -u "$U:$P" -H "$CRUMB" -H 'Content-Type: application/xml' \
       --data-binary @"$LAB_ROOT/ci/deploy-service.job.xml" "$J/createItem?name=deploy-service")
case "$CODE" in
  200) ok "created: $J/job/deploy-service" ;;
  400) warn "already exists: $J/job/deploy-service" ;;
  *)   die "Jenkins returned HTTP $CODE — create it in the UI instead" ;;
esac
say "  Open it, click 'Build with Parameters'. The first run registers the parameters; if the"
say "  button says just 'Build', run once, then it will say 'Build with Parameters'."
