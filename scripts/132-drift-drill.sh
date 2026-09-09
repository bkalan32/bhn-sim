#!/usr/bin/env bash
# Day 13, Step 5 — drift, the incident-flavoured payoff. INC-0015.
#
#   ./scripts/132-drift-drill.sh inject    a colleague "hot-fixes" pushgateway by hand:
#                                          helm upgrade --set serviceMonitor.enabled=false --reuse-values
#                                          Prometheus quietly stops scraping it. Nobody remembers.
#   ./scripts/132-drift-drill.sh detect    terraform plan -detailed-exitcode -> exit 2, and the exact line
#   ./scripts/132-drift-drill.sh observe   what the platform sees with settlement's metrics gone — dashboards,
#                                          the alert that CANNOT fire, the bot's collector, the copilot —
#                                          and a human-declared ticket, because nothing else opens one
#   ./scripts/132-drift-drill.sh repair    terraform apply restores it; metrics return; ticket closed
#
# Why this is the whole argument for IaC in one incident: application changes are tracked
# by the pipeline (Day 6). Infrastructure changes — someone editing a chart's values, bumping
# a version, tweaking a namespace — are the untracked class, and they produce the confusing
# incidents: nothing crashed, nothing alerted, a metric just stopped. Terraform's plan is the
# diff between "what we said" and "what is", and the nightly job (133) makes it an alert.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"

case "${1:-}" in
  inject)
    step "Preconditions"
    "$TF" plan -input=false -detailed-exitcode >/dev/null 2>&1 && ok "plan clean before the drill (so anything we find is ours)" || die "plan is not clean — ./infra/local/tf.sh plan, fix, then inject"
    [[ -z "$(open_ids_for settlement)" ]] || die "a settlement incident is already open"
    step "The hot-fix nobody will remember: serviceMonitor off, by hand, outside the code"
    helm upgrade pushgateway prometheus-community/prometheus-pushgateway --kube-context "$KUBE_CONTEXT" -n "$MONITORING_NS" \
      --version "$(grep -oE '"pushgateway" = "[0-9.]+"' infra/local/chart-versions.auto.tfvars | grep -oE '[0-9.]+$')" \
      --set serviceMonitor.enabled=false --reuse-values --wait --timeout 3m >/dev/null
    ok "pushgateway revision $(helm list -n "$MONITORING_NS" --kube-context "$KUBE_CONTEXT" -o json | python3 -c 'import json,sys; print([r["revision"] for r in json.load(sys.stdin) if r["name"]=="pushgateway"][0])') — ServiceMonitor deleted; Prometheus drops the target within ~1 min"
    date -u +%FT%TZ > checkpoints/day13-drift-injected.txt
    say "  Nothing crashed. No alert will fire. That is the point."
    ok "Next: $0 detect"
    ;;
  detect)
    step "terraform plan -detailed-exitcode  (0 = clean, 1 = error, 2 = DRIFT)"
    set +e; "$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1; RC=$?; set -e
    case "$RC" in
      2) ok "exit code 2: DRIFT. The diff, precisely:"
         grep -nE '~ resource|Plan:|ServiceMonitor' infra/local/plan.txt | grep -vE '^\s*[0-9]+:\s*#' | head -12 | cut -c1-160 | sed 's/^/  /'
         say ""; say "  Code says serviceMonitor.enabled=true (k8s/pushgateway-values.yaml); the cluster has no ServiceMonitor."
         say "  Terraform did not guess — it rendered the chart with your values (a dry-run upgrade) and diffed"
         say "  that against the manifest the cluster is running (provider experiments.manifest, B8)." ;;
      0) warn "plan is clean — no drift detected. Two possible reasons:"
         say "    1. inject did not run:  helm get values pushgateway -n monitoring | grep -A1 serviceMonitor"
         say "    2. the helm provider is not comparing live state: infra/local/providers.tf must have"
         say "       experiments = { manifest = true }  (CORRECTIONS-DAY13 B8) — then plan again" ;;
      *) die "plan failed: $(tail -5 infra/local/plan.txt)" ;;
    esac
    ok "Next: $0 observe"
    ;;
  observe)
    step "What the platform sees with settlement's metrics silently gone"
    say "  Prometheus targets for pushgateway:"
    N=$(k get servicemonitor -n "$MONITORING_NS" 2>/dev/null | grep -c pushgateway || true); say "    ServiceMonitors named pushgateway: $N   (was 1)"
    say "  settlement_last_success_timestamp:  $(promql 'settlement_last_success_timestamp' | python3 tools/promjson.py value '{:.0f}')"
    say "  settlement:health_score:            $(promql 'settlement:health_score' | python3 tools/promjson.py value '{:.0f}')"
    say "  SettlementStale expression:         $(promql 'time() - settlement_last_success_timestamp > 900' | python3 tools/promjson.py value '{:.0f}')   <- empty = the alert CANNOT fire, however stale settlement gets"
    say "  the bot's collector for settlement:"
    python3 tools/inc.py enrich-test settlement | python3 -c 'import json,sys; d=json.load(sys.stdin); print("    metrics:", json.dumps(d["context"]["metrics"]))'
    echo
    say "  Ask the copilot — it should say 'not available', not a number:"
    python3 tools/copilot.py -q "Is settlement healthy right now? When did it last succeed and how many records? Answer only from tools." --tag drift-drill --no-transcript 2>/dev/null | tail -12 | sed 's/^/  /' || warn "copilot unavailable (key?) — skip"
    echo
    step "Declaring the incident by hand — nothing else will"
    [[ -z "$(open_ids_for settlement)" ]] || die "a settlement incident is already open"
    python3 tools/inc.py declare settlement "settlement panels blank, SettlementStale cannot fire: pushgateway metrics stopped flowing (cause unknown at declare time)"
    ID=$(open_ids_for settlement | awk '{print $1}'); [[ -n "$ID" ]] || die "no ticket"
    sleep 3
    python3 tools/inc.py note "$ID" "terraform plan -detailed-exitcode = 2: pushgateway serviceMonitor.enabled=false in the cluster, true in code. Untracked infrastructure change; drift injected $(cat checkpoints/day13-drift-injected.txt 2>/dev/null || echo '?') (drill)" >/dev/null
    ok "INCIDENT $ID open with the drift on the record   -> INC-0015"
    ok "Next: $0 repair"
    ;;
  repair)
    ID=$(open_ids_for settlement | awk '{print $1}')
    step "terraform apply — the code is the fix"
    set +e; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1; RC=$?; set -e
grep -E '^(helm_release|Apply complete)|^\s*(│ )?Error:' infra/local/apply.txt | sed 's/^/  /'
(( RC == 0 )) || die "terraform apply failed (exit $RC) — full output: infra/local/apply.txt"
    step "Metrics back?"
    OK=0; for _ in $(seq 1 24); do
      v=$(promql 'settlement_last_success_timestamp' | python3 tools/promjson.py value '{:.0f}'); [[ "$v" != "no data" ]] && { OK=1; break; }; sleep 5
    done
    (( OK )) && ok "settlement_last_success_timestamp is being scraped again ($(promql 'time() - settlement_last_success_timestamp' | python3 tools/promjson.py value '{:.0f}')s since last success)" \
      || warn "still no data after 2 min — kubectl get servicemonitor -n monitoring | grep pushgateway"
    "$TF" plan -input=false -detailed-exitcode >/dev/null 2>&1 && ok "plan clean" || warn "plan not clean"
    if [[ -n "$ID" ]]; then
      python3 tools/inc.py note "$ID" "repaired by terraform apply at $(date -u +%FT%TZ) — pushgateway ServiceMonitor restored from code. Permanent fix: nightly drift check (Jenkins infra-drift-check)" >/dev/null
      python3 tools/inc.py undeclare settlement >/dev/null
      ok "ticket $ID resolved   -> write incidents/INC-0015.md"
    fi
    ok "Next: ./scripts/133-drift-check-job.sh"
    ;;
  *) die "usage: $0 inject|detect|observe|repair" ;;
esac
