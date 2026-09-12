#!/usr/bin/env bash
# Day 18, Part C, Step 4 — the daily ops report on a schedule: a Jenkins job (H 7 * * *),
# created through the API like the drift check (Day 13), run once now, the report fetched
# from the bot's store into reports/daily/.
#
#   ./scripts/183-daily-report-job.sh             create daily-ops-report, run it, fetch today's report
#   ./scripts/183-daily-report-job.sh --run       run it again (after a drill, tomorrow morning) and fetch
#   JENKINS_USER=admin JENKINS_PASS=... ./scripts/183-daily-report-job.sh
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
U="${JENKINS_USER:-admin}"; P="${JENKINS_PASS:-}"
J=http://localhost:8081; JOB=daily-ops-report
[[ -n "$P" ]] || { read -rsp "Jenkins password for $U: " P; echo; }

step "Preconditions"
docker run --rm --entrypoint sh jenkins-lab -c 'command -v terraform && command -v python3 && command -v kubectl' >/dev/null 2>&1 && ok "jenkins-lab has terraform, python3, kubectl" || die "jenkins-lab image lacks a tool — ./scripts/133-drift-check-job.sh rebuilt it on Day 13"
bot_get /ai | grep -q '"enabled": *true' && ok "the bot's AI is enabled (the report uses the same key: secret/ai-keys)" || warn "bot /ai says AI is not enabled — the report needs secret/ai-keys (90-ai-secret.sh)"
bot_get /reports >/dev/null && ok "the bot has the /reports store (Day 18 build)" || die "the running bot has no /reports — Jenkins deploy-service SERVICE=incident-bot first"
git -C "$LAB_ROOT" diff --quiet -- tools/daily_report.py ci/Jenkinsfile.daily-report 2>/dev/null && ok "daily_report.py and the Jenkinsfile are committed (the job clones /repo)" || warn "uncommitted changes to the report tooling — the job runs what is COMMITTED"

JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT
crumb() { curl -fsS -c "$JAR" -u "$U:$P" "$J/crumbIssuer/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"]+":"+d["crumb"])' 2>/dev/null || true; }
if [[ "${1:-}" != --run ]]; then
  step "Creating job $JOB (ci/daily-ops-report.job.xml -> ci/Jenkinsfile.daily-report)"
  CRUMB=$(crumb); [[ -n "$CRUMB" ]] || die "could not authenticate to Jenkins as $U"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$JAR" -u "$U:$P" -H "$CRUMB" -H 'Content-Type: application/xml' \
         --data-binary @"$LAB_ROOT/ci/daily-ops-report.job.xml" "$J/createItem?name=$JOB")
  case "$CODE" in
    200) ok "created: $J/job/$JOB" ;;
    400) ok "already exists: $J/job/$JOB" ;;
    *)   die "Jenkins returned HTTP $CODE creating the job" ;;
  esac
fi

step "Running it now (plan ~90 s + gather ~30 s + one model call)"
before=$(curl -fsS -u "$U:$P" "$J/job/$JOB/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["lastBuild"]["number"] if d.get("lastBuild") else 0)' 2>/dev/null || echo 0)
CRUMB=$(crumb)
curl -s -o /dev/null -b "$JAR" -u "$U:$P" -H "$CRUMB" -X POST "$J/job/$JOB/build" || die "could not trigger the build"
printf '  build queued (last was #%s), waiting' "$before"
RES=RUNNING; after=0
for _ in $(seq 1 90); do
  sleep 5; printf '.'
  after=$(curl -fsS -u "$U:$P" "$J/job/$JOB/api/json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); b=d.get("lastBuild") or {}; print(b.get("number",0))' 2>/dev/null || echo 0)
  if (( after > before )); then
    RES=$(curl -fsS -u "$U:$P" "$J/job/$JOB/$after/api/json" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result") or "RUNNING")' 2>/dev/null || echo RUNNING)
    [[ "$RES" != RUNNING ]] && { echo; break; }
  fi
done
say "  build #$after: $RES   ($J/job/$JOB/$after/console)"
[[ "$RES" == SUCCESS ]] || die "the report job did not succeed — read the console; python3 tools/daily_report.py --dry shows which collector failed"

step "The report, from the bot's store"
DAY=$(date -u +%F)
python3 tools/daily_report.py --fetch "$DAY" && sed -n '1,40p' "reports/daily/$DAY.md" | sed 's/^/  /'
curl -fsS -u "$U:$P" "$J/job/$JOB/$after/consoleText" 2>/dev/null | grep -E '^\S+ +-- [0-9]+ words' | sed 's/^/  /' || true
ok "Scheduled: H 7 * * * (registered by this first run). The laptop must be awake at 07:00 for it to fire — a run that never happened is a missing report, which the morning checklist notices."
ok "Next: grade it in docs/ai-eval.md Eval 9 (every number traceable? boring day = boring report?), then ./scripts/188-checkpoint-day18.sh"
