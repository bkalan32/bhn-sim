#!/usr/bin/env bash
# ============================================================================
#  GAME DAY 1 — "the friday afternoon special"            DO NOT READ BEFORE THE RETRO
#
#  You wrote this in the morning. The whole point of the afternoon is that you half-forgot it.
#  scripts/142-gameday.sh start runs it in the background; scripts/142-gameday.sh retro shows it.
# ============================================================================
set -u
CTX="${KUBE_CONTEXT:-kind-bhn-sim}"; NS=payments
LOG="$(dirname "$0")/.scenario-1.log"
t() { date -u +%FT%TZ; }
echo "$(t) scenario-1 start" >> "$LOG"

# Fault 1 — loud: a partner's email delivery degrades. 35% of eGift orders fail at the
# send_email step. Activation is fine. No deploy happened. The trap is to look at activation
# because that is where every previous egift incident came from.
kubectl --context "$CTX" -n "$NS" set env deployment/egift EMAIL_FAIL_RATE=0.35 >/dev/null 2>&1 \
  && echo "$(t) fault-1 injected: egift EMAIL_FAIL_RATE=0.35 (partner email degradation)" >> "$LOG" \
  || echo "$(t) fault-1 FAILED to inject" >> "$LOG"

sleep 180

# Fault 2 — quiet, and unrelated: settlement starts reconciling zero records. Because the
# job self-checks since Day 8 (STRICT), it exits 2 -> SettlementJobFailed -> the remediator
# re-runs it -> it fails again (the mode is still set) -> retry in 180 s -> fails again ->
# "human required". SettlementStale follows at 15 min. Nothing about this is in the egift
# ticket. The trap is anchoring on fault 1 and never noticing the second row on the overview.
kubectl --context "$CTX" -n "$NS" set env cronjob/settlement SETTLEMENT_FAIL_MODE=silent >/dev/null 2>&1 \
  && echo "$(t) fault-2 injected: settlement SETTLEMENT_FAIL_MODE=silent (next cron tick, <=5 min)" >> "$LOG" \
  || echo "$(t) fault-2 FAILED to inject" >> "$LOG"

echo "$(t) scenario-1 done — two faults live; nothing else will happen. Find both." >> "$LOG"
