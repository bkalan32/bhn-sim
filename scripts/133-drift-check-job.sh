#!/usr/bin/env bash
# Day 13, Step 5b — infrastructure drift becomes an alert like any other: a nightly Jenkins
# job that runs `terraform plan -detailed-exitcode` and goes red on exit code 2.
#
#   ./scripts/133-drift-check-job.sh            rebuild the Jenkins image with terraform, create the job,
#                                               run it once (expect SUCCESS: no drift right now)
#   ./scripts/133-drift-check-job.sh --prove    also: inject the pushgateway drift, run the job, expect
#                                               FAILURE, repair with terraform apply, run again, expect SUCCESS
#
# Usage: JENKINS_USER=admin JENKINS_PASS=... ./scripts/133-drift-check-job.sh [--prove]
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
U="${JENKINS_USER:-admin}"; P="${JENKINS_PASS:-}"
J=http://localhost:8081; JOB=infra-drift-check
TF="$LAB_ROOT/infra/local/tf.sh"

step "Preconditions"
[[ -f infra/local/terraform.tfstate ]] || die "no infra/local/terraform.tfstate — ./scripts/130-tf-import.sh first"
"$TF" plan -input=false -detailed-exitcode >/dev/null 2>&1 && ok "plan clean now (the first job run should be green)" || die "plan is not clean — ./scripts/132-drift-drill.sh repair (or ./infra/local/tf.sh plan) before creating the job"
[[ -n "$P" ]] || { read -rsp "Jenkins password for $U: " P; echo; }

step "Does the Jenkins image have terraform?"
if docker run --rm --entrypoint sh jenkins-lab -c 'command -v terraform' >/dev/null 2>&1; then
  ok "jenkins-lab already carries terraform"
else
  say "  rebuilding jenkins-lab (ci/Dockerfile.jenkins now installs terraform) — jobs and history live in the jenkins_home volume and survive"
  "$LAB_ROOT/scripts/50-jenkins-rebuild.sh"
fi

JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
crumb() { curl -fsS -c "$JAR" -u "$U:$P" "$J/crumbIssuer/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])' 2>/dev/null || true; }
step "Creating job $JOB"
for _ in $(seq 1 30); do curl -fsS -o /dev/null "$J/login" 2>/dev/null && break; sleep 3; done
CRUMB=$(crumb); [[ -n "$CRUMB" ]] || die "could not authenticate to Jenkins as $U"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -u "$U:$P" -H "$CRUMB" -H 'Content-Type: application/xml' \
       --data-binary @"$LAB_ROOT/ci/infra-drift-check.job.xml" "$J/createItem?name=$JOB")
case "$CODE" in
  200) ok "created: $J/job/$JOB" ;;
  400) ok "already exists: $J/job/$JOB" ;;
  *)   die "Jenkins returned HTTP $CODE creating the job" ;;
esac

run_job() {  # expect_result
  local expect="$1" before after n
  before=$(curl -fsS -u "$U:$P" "$J/job/$JOB/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["lastBuild"]["number"] if d.get("lastBuild") else 0)' 2>/dev/null || echo 0)
  CRUMB=$(crumb)
  curl -s -o /dev/null -b "$JAR" -u "$U:$P" -H "$CRUMB" -X POST "$J/job/$JOB/build" || die "could not trigger the build"
  printf '  build queued (last was #%s), waiting' "$before"
  for _ in $(seq 1 90); do
    sleep 5; printf '.'
    after=$(curl -fsS -u "$U:$P" "$J/job/$JOB/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); b=d.get("lastBuild") or {}; print(b.get("number",0))' 2>/dev/null || echo 0)
    if (( after > before )); then
      RES=$(curl -fsS -u "$U:$P" "$J/job/$JOB/$after/api/json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result") or "RUNNING")' 2>/dev/null || echo RUNNING)
      [[ "$RES" != RUNNING ]] && { echo; break; }
    fi
  done
  say "  build #$after: $RES   ($J/job/$JOB/$after/console)"
  if [[ "$RES" == "$expect" ]]; then ok "as expected: $expect"; else warn "expected $expect, got $RES — read the console"; return 1; fi
}

step "Run 1 — no drift: expect SUCCESS (the first run also registers the nightly cron trigger, H 3 * * *)"
run_job SUCCESS || die "the drift job does not pass on a clean plan — fix that before trusting it"

if [[ "${1:-}" == "--prove" ]]; then
  step "Run 2 — WITH drift: expect FAILURE"
  helm upgrade pushgateway prometheus-community/prometheus-pushgateway --kube-context "$KUBE_CONTEXT" -n "$MONITORING_NS" \
    --version "$(grep -oE '"pushgateway" = "[0-9.]+"' infra/local/chart-versions.auto.tfvars | grep -oE '[0-9.]+$')" \
    --set serviceMonitor.enabled=false --reuse-values --wait --timeout 3m >/dev/null && ok "drift injected"
  run_job FAILURE || warn "the job went green with drift present — the plan it ran was clean? check TF_STATE_PATH in the console"
  step "Repair"
  "$TF" apply -input=false -auto-approve -no-color 2>&1 | grep -E 'Apply complete|Error' | sed 's/^/  /'
  step "Run 3 — repaired: expect SUCCESS"
  run_job SUCCESS || true
fi

echo
ok "Nightly at ~03:00 (H 3 * * *) the job plans; exit 2 turns it red. Infrastructure drift is now an alert."
ok "Next: write incidents/INC-0015.md, then ./scripts/138-checkpoint-day13.sh"
