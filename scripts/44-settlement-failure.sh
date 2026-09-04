#!/usr/bin/env bash
# Day 5, Step 10 — run the settlement failure modes and watch which alerts notice.
#
#   ./scripts/44-settlement-failure.sh crash    loud: Job Failed, SettlementJobFailed
#   ./scripts/44-settlement-failure.sh silent   zero records. Day 5: quiet. Day 8+: the job refuses (strict default)
#   ./scripts/44-settlement-failure.sh none     reset
#   ./scripts/44-settlement-failure.sh strict   zero records + SETTLEMENT_STRICT=true (same as silent since Day 8)
#   ./scripts/44-settlement-failure.sh lenient  zero records + SETTLEMENT_STRICT=false — the Day 5 behaviour, for comparison
#
# Day 8: SETTLEMENT_STRICT defaults to true in k8s/settlement.yaml (INC-0005's fix
# shipped). crash/silent/none no longer touch STRICT; only `lenient` turns it off.
source "$(dirname "$0")/lib.sh"
require_cluster
MODE="${1:-}"
case "$MODE" in
  crash|silent|none) FAIL="$MODE"; STRICT=true ;;
  strict)  FAIL=silent; STRICT=true ;;
  lenient) FAIL=silent; STRICT=false ;;
  *) die "Usage: $0 crash|silent|none|strict|lenient" ;;
esac

trap 'if [[ "$FAIL" != none ]]; then warn "leaving CronJob in mode=$FAIL strict=$STRICT — run: $0 none"; fi' EXIT

step "Setting CronJob env: SETTLEMENT_FAIL_MODE=$FAIL SETTLEMENT_STRICT=$STRICT"
k set env cronjob/settlement -n "$PAYMENTS_NS" "SETTLEMENT_FAIL_MODE=$FAIL" "SETTLEMENT_STRICT=$STRICT"
dim "(set env on a CronJob only affects FUTURE jobs — so we trigger one now)"

step "Running it now"
JOB="settlement-${MODE}-$(date +%s)"
k create job "$JOB" --from=cronjob/settlement -n "$PAYMENTS_NS" >/dev/null
sleep 3
for _ in $(seq 1 40); do
  ST=$(k get job "$JOB" -n "$PAYMENTS_NS" -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || true)
  [[ "$ST" == "Complete" || "$ST" == "Failed" ]] && break; sleep 3
done
say "  Kubernetes says:  ${ST:-still running}"
say "  The job's own log:"
k logs -n "$PAYMENTS_NS" "job/$JOB" 2>/dev/null | python3 "$LAB_ROOT/tools/logfmt.py"

step "What the metrics say (after the push lands)"
sleep 25
for m in settlement_records_processed settlement_last_run_status; do
  printf '  %-32s %s\n' "$m" "$(promql "$m" | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')"
done
AGE=$(promql 'time() - settlement_last_success_timestamp' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
printf '  %-32s %ss ago\n' "last SUCCESS" "$AGE"

step "Which alerts notice (give them 60-90s to go Pending -> Firing)"
sleep 75
SVC="${PROM_SVC:-$(prom_svc || true)}"
PF=""; k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 & PF=$!; sleep 3
curl -fsS http://localhost:9090/api/v1/rules | python3 "$LAB_ROOT/tools/promjson.py" rules Settlement || true
kill "$PF" 2>/dev/null || true

case "$MODE" in
  crash)  say ""; say "  LOUD. Kubernetes: Failed. SettlementJobFailed fires now; SettlementStale joins after 15 min."; ;;
  lenient) say ""; say "  Kubernetes: Succeeded. Log: 'settlement complete'. Exit 0. Nothing red anywhere."
          say "  Only SettlementZeroRecords knows. Without it, you find out from finance."
          say "  This is INC-0005 as it happened on Day 5 — the most realistic failure in the series." ;;
  silent|strict) say ""; say "  Zero records, but the JOB refuses to call it success: exit 2, Job Failed, and the"
          say "  log names the reason. INC-0005's fix, default since Day 8. Kubernetes, the log,"
          say "  SettlementJobFailed and SettlementZeroRecords all agree — four signals, not one."
          say "  The alerts are now the backstop, not the only line of defence." ;;
  none)   say ""; ok "baseline restored. SettlementStale clears on the next successful run." ;;
esac
