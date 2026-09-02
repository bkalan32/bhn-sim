#!/usr/bin/env bash
# Day 5, Steps 7-8 — build the settlement job, schedule it, and run it once NOW rather
# than waiting up to 5 minutes for the first tick.
source "$(dirname "$0")/lib.sh"
require_docker; require_cluster

step "Building settlement:0.1"
build_service settlement 0.1

step "Scheduling (every 5 minutes stands in for nightly)"
k apply -f "$LAB_ROOT/k8s/settlement.yaml"
k get cronjob settlement -n "$PAYMENTS_NS"

step "Triggering one run immediately"
JOB="settlement-manual-$(date +%s)"
k create job "$JOB" --from=cronjob/settlement -n "$PAYMENTS_NS" >/dev/null
k wait --for=condition=complete "job/$JOB" -n "$PAYMENTS_NS" --timeout=120s \
  && ok "job $JOB completed" || warn "job did not complete in 2 min: kubectl describe job/$JOB -n payments"
k logs -n "$PAYMENTS_NS" "job/$JOB" 2>/dev/null | python3 "$LAB_ROOT/tools/logfmt.py"

step "Did the metrics land in Prometheus? (via Pushgateway — scraped every 30s, so up to ~60s)"
V="no data"
for _ in $(seq 1 8); do
  sleep 10
  V=$(promql 'settlement_records_processed' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
  [[ "$V" != "no data" ]] && break
  printf '  waiting for scrape...\n'
done
if [[ "$V" != "no data" ]]; then
  ok "settlement_records_processed = $V"
else
  warn "not in Prometheus after 80s. Narrowing it down:"
  PGSVC=$(k get svc -n "$MONITORING_NS" -o name | sed 's|service/||' | grep -i pushgateway | head -1 || true)
  if [[ -n "$PGSVC" ]]; then
    PF=""; k port-forward -n "$MONITORING_NS" "svc/$PGSVC" 9091:9091 >/dev/null 2>&1 & PF=$!; sleep 2
    if curl -fsS localhost:9091/metrics 2>/dev/null | grep -q '^settlement_records_processed'; then
      ok "the Pushgateway HAS the metric — so the job is fine and Prometheus is not scraping the gateway"
      if k get servicemonitor -n "$MONITORING_NS" 2>/dev/null | grep -qi pushgateway; then
        REL=$(k get servicemonitor -n "$MONITORING_NS" -o jsonpath='{.items[?(@.metadata.name=="'"$PGSVC"'")].metadata.labels.release}' 2>/dev/null || true)
        [[ "$REL" == "$HELM_RELEASE" ]] && warn "ServiceMonitor has release=$REL; check Prometheus > Status > Targets for a pushgateway target" \
          || die "ServiceMonitor release='$REL' != '$HELM_RELEASE'. Fix: kubectl label servicemonitor -n monitoring $PGSVC release=$HELM_RELEASE --overwrite"
      else
        die "no ServiceMonitor for the pushgateway. Re-run ./scripts/42-install-pushgateway.sh"
      fi
    else
      die "the Pushgateway does NOT have the metric — the job's push failed. kubectl logs -n payments job/$JOB"
    fi
    kill "$PF" 2>/dev/null || true
  else
    die "no pushgateway service in $MONITORING_NS — run ./scripts/42-install-pushgateway.sh first"
  fi
fi
ok "Next: ./scripts/44-settlement-failure.sh crash | silent"
