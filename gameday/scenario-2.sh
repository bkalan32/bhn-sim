#!/usr/bin/env bash
# ============================================================================
#  GAME DAY 2 — "the quarter-end special", on EKS          DO NOT READ BEFORE THE RETRO
#
#  Three faults, staggered, chosen so that each layer has to answer a different way:
#  investigate / let the automation work / escalate outside. The gaps are jittered so the
#  clock does not tell you what the platform should. scripts/192-gameday2.sh start runs it
#  in the background against KUBE_CONTEXT (aws-lab by default); retro shows this file.
# ============================================================================
set -u
CTX="${KUBE_CONTEXT:-aws-lab}"; NS=payments
LOG="$(dirname "$0")/.scenario-2.log"
t() { date -u +%FT%TZ; }
j() { echo $(( $1 + RANDOM % 90 )); }        # $1 .. $1+89 seconds
echo "$(t) scenario-2 start (context $CTX)" >> "$LOG"

# Fault 1 — slow, no errors: activation's own work gets 7x slower (BASE_LATENCY_MS 80 -> 600).
# No dependency is involved, no deploy happened, the error rate stays at its baseline. The
# only alert that CAN fire is Day 18's latency-SLO burn (ActivationLatencyBudgetBurn, a
# warning = a ticket, not a page) — and its 1h window needs ~9 minutes of this before it
# crosses. The health score sags at once on the overview. Correct response: investigate,
# conclude "internal latency regression, no deploy, no slow dependency", keep watching —
# and say plainly that the lab cannot tell an env knob from a real regression.
kubectl --context "$CTX" -n "$NS" set env deployment/activation BASE_LATENCY_MS=600 >/dev/null 2>&1 \
  && echo "$(t) fault-1 injected: activation BASE_LATENCY_MS=600 (creeping latency, no errors; the latency-SLO burn is the only alert that can fire, ~9 min)" >> "$LOG" \
  || echo "$(t) fault-1 FAILED to inject" >> "$LOG"

sleep "$(j 200)"

# Fault 2 — loud and KNOWN: settlement starts crashing (exit non-zero every run). kb-004.
# SettlementJobFailed within a minute of the next cron tick -> the remediator's tier-1
# re-run (settlement-crash signature) -> the re-run crashes too (the mode is still set) ->
# retry after 180 s -> crashes again -> "human required" on the timeline. YOU are the
# vendor: reset the mode (SETTLEMENT_FAIL_MODE=none) when you see the second failure, and
# watch the NEXT automated run succeed on its own, staleness clear, the ticket resolve with
# no further human action. One incident handled almost entirely by the machine, on record.
kubectl --context "$CTX" -n "$NS" set env cronjob/settlement SETTLEMENT_FAIL_MODE=crash >/dev/null 2>&1 \
  && echo "$(t) fault-2 injected: settlement SETTLEMENT_FAIL_MODE=crash (next cron tick <=5 min; tier-1 re-runs will fail until you reset the mode)" >> "$LOG" \
  || echo "$(t) fault-2 FAILED to inject" >> "$LOG"

sleep "$(j 200)"

# Fault 3 — loud and EXTERNAL: the email partner falls over, half of eGift orders fail at
# send_email (kb-003, INC-0003/0016). EgiftHighErrorRate within ~3 min. The hypothesis
# should cite kb-003 by id and recommend escalation to the partner, NOT a remediation
# (there is no signature, and there must not be). You post the would-be partner ticket as
# a note and resolve by resetting the rate. Activation is unaffected — the trap, as on Day 14,
# is to look there because that is where fault 1 is.
kubectl --context "$CTX" -n "$NS" set env deployment/egift EMAIL_FAIL_RATE=0.5 >/dev/null 2>&1 \
  && echo "$(t) fault-3 injected: egift EMAIL_FAIL_RATE=0.5 (partner email degradation; kb-003; escalate, do not remediate)" >> "$LOG" \
  || echo "$(t) fault-3 FAILED to inject" >> "$LOG"

echo "$(t) scenario-2 done — three faults live; nothing else will happen. Three different correct responses." >> "$LOG"
