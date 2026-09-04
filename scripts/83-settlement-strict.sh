#!/usr/bin/env bash
# Day 8, Step 4a — INC-0005's follow-up: the job refuses to report success on zero
# records, BY DEFAULT. Verify all three failure modes against the deployed image.
#
#   ./scripts/83-settlement-strict.sh          verify what the pipeline deployed
#   ./scripts/83-settlement-strict.sh --local  build settlement:0.2 here and apply it first
#                                              (if you skipped the pipeline)
#
# Each mode takes ~2.5 minutes (job + Pushgateway scrape + alert `for:`). ~8 minutes total.
source "$(dirname "$0")/lib.sh"
require_cluster

if [[ "${1:-}" == "--local" ]]; then
  require_docker
  step "Building settlement:0.2 locally"
  build_service settlement 0.2
  k apply -f "$LAB_ROOT/k8s/settlement.yaml"
fi

step "What is deployed?"
IMG=$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)
STRICT=$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_STRICT")].value}' 2>/dev/null || true)
say "  image=$IMG   SETTLEMENT_STRICT=${STRICT:-<unset → code default: true>}"
case "$IMG" in
  settlement:0.1) die "still the Day 5 image. Ship 0.2: Jenkins SERVICE=settlement, or re-run with --local" ;;
  "") die "no settlement CronJob — ./scripts/43-build-settlement.sh" ;;
esac
[[ "$STRICT" == "false" ]] && warn "STRICT is explicitly false on the CronJob — a drill left it. This script's modes set it true."

step "Mode 1/3: silent (zero records) — the job must now REFUSE"
"$LAB_ROOT/scripts/44-settlement-failure.sh" silent
LAST=$(k get jobs -n "$PAYMENTS_NS" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || true)
if k logs -n "$PAYMENTS_NS" "job/$LAST" 2>/dev/null | grep -q 'refusing to report success'; then
  ok "job $LAST logged 'refusing to report success' and exited 2"
else
  warn "expected 'refusing to report success' in job/$LAST logs — is the 0.2 image actually running?"
fi

step "Mode 2/3: crash — still loud"
"$LAB_ROOT/scripts/44-settlement-failure.sh" crash

step "Mode 3/3: none — back to healthy"
"$LAB_ROOT/scripts/44-settlement-failure.sh" none

step "For contrast (optional): the Day 5 behaviour"
say "  ./scripts/44-settlement-failure.sh lenient   # STRICT=false: exit 0, 'settlement complete', 0 records"
say "  ./scripts/44-settlement-failure.sh none      # then reset"
echo
say "Write it down: incidents/INC-0005.md — tick the follow-up, add 'fix verified' with the job name."
ok "Next: ./scripts/84-test-catches-bug.sh"
