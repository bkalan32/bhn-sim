#!/usr/bin/env bash
# Day 12, Step 4 — the two tier-1 drills. Automation runs without asking; you watch what
# it writes on the ticket and whether the fix STUCK.
#
#   ./scripts/122-drill-tier1.sh crashloop    a throwaway Deployment `crashtest` whose container
#                                             exits 1 -> PaymentsPodCrashLooping (2 min) -> ticket ->
#                                             remediator deletes THAT pod -> Deployment replaces it ->
#                                             it crash-loops again -> the follow-up note says "did NOT
#                                             stick — this is real". INC-0012.
#   ./scripts/122-drill-tier1.sh settlement   SETTLEMENT_FAIL_MODE=crash -> SettlementJobFailed (1 min)
#                                             -> ticket -> remediator re-runs the job -> it crashes too
#                                             (mode still crash) -> FAILED note + "retry in 180 s". You
#                                             set the mode back to none; the retry succeeds and
#                                             last_success recovers without you touching kubectl. INC-0013.
#
# Why a throwaway Deployment for the crash-loop and not egift patched to `false` (the PDF):
# patching egift's command takes BOTH egift pods down — a real outage for a tier-1 test. A
# fixture with its own name is in the alert's service regex and the Alertmanager route
# (CORRECTIONS-DAY12 B5) and is deleted at the end.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
MODE="${1:-}"

precheck() {
  step "Preconditions"
  rem_get /healthz | grep -q '"status"' || die "remediator not answering — Jenkins SERVICE=remediator"
  rem_get /signatures | grep -q '"dry_run": *false' || warn "DRY_RUN is on — the remediator will only SAY what it would do"
  alertmanager_get /api/v2/status | grep -q remediator || die "Alertmanager is not fanning out to the remediator — ./scripts/121-remediator-route.sh"
  ok "remediator up, fan-out configured"
}

case "$MODE" in
  crashloop)
    precheck
    [[ -z "$(open_ids_for crashtest)" ]] || die "a crashtest incident is already open — wait for it to close"
    step "Creating the fixture: Deployment crashtest (1 replica, command exits 1)"
    cat <<'EOF' | k apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: crashtest
  namespace: payments
  labels: {app: crashtest, bhn-sim/drill: day12-tier1}
spec:
  replicas: 1
  selector: {matchLabels: {app: crashtest}}
  template:
    metadata:
      labels: {app: crashtest}
    spec:
      containers:
        - name: crashtest
          image: busybox:1.36
          command: ["sh", "-c", "echo 'crashtest: simulated fatal error at startup'; exit 1"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
EOF
    T0=$(date +%s); ok "created at $(date -u +%T)Z — CrashLoopBackOff begins after 2-3 restarts (~1 min), the alert 2 min after that"
    trap 'warn "removing the fixture"; kubectl --context "$KUBE_CONTEXT" delete deployment crashtest -n "$PAYMENTS_NS" --ignore-not-found >/dev/null 2>&1 || true' EXIT

    step "Waiting for the ticket (≈3-4 min)"
    ID=$(wait_open_for crashtest "" 420) || die "no crashtest incident after 7 min — is PaymentsPodCrashLooping in Prometheus > Rules? kubectl get pods -n payments -l app=crashtest"
    ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

    step "Watching the remediator (AUTO note, then the 90-second follow-up)"
    for _ in $(seq 1 40); do
      N=$(rem_notes "$ID"); [[ "$N" == *"follow-up"* ]] && break; sleep 5
    done
    rem_notes "$ID" | sed 's/^/  │ /'
    echo
    k get pods -n "$PAYMENTS_NS" -l app=crashtest 2>/dev/null | sed 's/^/  /'
    say ""
    say "  What you just saw: the restart fixed nothing — the Deployment replaced the pod and the"
    say "  replacement crash-loops too. The note + the still-firing alert is the signal 'this is real'."
    say "  A naive self-healer would keep deleting forever; the cooldown stops the second delete."
    step "Removing the fixture (the alert resolves in ~1 min, the ticket closes)"
    k delete deployment crashtest -n "$PAYMENTS_NS" --ignore-not-found >/dev/null; trap - EXIT
    wait_resolved "$ID" 300 || warn "still open after 5 min — the alert needs the CrashLoopBackOff series to disappear"
    ok "INCIDENT $(field "$ID" status): $ID   -> write incidents/INC-0012.md"
    ;;

  settlement)
    precheck
    [[ -z "$(open_ids_for settlement)" ]] || die "a settlement incident is already open — wait for it to close"
    step "Breaking settlement: SETTLEMENT_FAIL_MODE=crash and one run now"
    k set env cronjob/settlement -n "$PAYMENTS_NS" SETTLEMENT_FAIL_MODE=crash >/dev/null
    JOB="settlement-drill-$(date +%s)"; k create job "$JOB" --from=cronjob/settlement -n "$PAYMENTS_NS" >/dev/null
    T0=$(date +%s); ok "job $JOB created — it crashes in seconds; SettlementJobFailed fires after 1 min"
    trap 'kubectl --context "$KUBE_CONTEXT" set env cronjob/settlement -n "$PAYMENTS_NS" SETTLEMENT_FAIL_MODE=none >/dev/null 2>&1 || true' EXIT

    step "Waiting for the ticket (≈1.5-2 min)"
    ID=$(wait_open_for settlement "" 300) || die "no settlement incident after 5 min"
    ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s)"

    step "The remediator re-runs the job — which ALSO crashes (mode is still crash)"
    for _ in $(seq 1 60); do N=$(rem_notes "$ID"); [[ "$N" == *"will retry once"* ]] && break; sleep 5; done
    rem_notes "$ID" | sed 's/^/  │ /'
    echo
    say "  Now fix the cause while the retry clock runs (180 s): mode back to none."
    k set env cronjob/settlement -n "$PAYMENTS_NS" SETTLEMENT_FAIL_MODE=none >/dev/null; trap - EXIT
    ok "SETTLEMENT_FAIL_MODE=none at $(date -u +%T)Z — you will not touch kubectl again"

    step "Waiting for the retry (up to 4 min)"
    for _ in $(seq 1 60); do N=$(rem_notes "$ID"); [[ "$N" == *"retry 1/1"* ]] && break; sleep 5; done
    rem_notes "$ID" | sed 's/^/  │ /'
    echo
    say "  last SUCCESS: $(promql 'time() - settlement_last_success_timestamp' | python3 tools/promjson.py value '{:.0f}')s ago"
    say ""
    say "  A genuine self-heal, witnessed end to end: the automation's first attempt reported an"
    say "  honest FAILURE (not a success note), waited, and the retry after the fix succeeded."
    say "  SettlementJobFailed keeps firing until 15 min after the LAST failed job started (its"
    say "  expression); the ticket closes then. Don't wait for it — write incidents/INC-0013.md."
    ;;
  *) die "usage: $0 crashloop|settlement" ;;
esac
