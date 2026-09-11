#!/usr/bin/env bash
# Day 17, Part A — New Relic wired in, as code, and PROVEN from inside the cluster.
#
#   1. the `newrelic` namespace (Terraform, targeted — a Secret needs a home)
#   2. the license key into Secrets (170, prompts once; idempotent after)
#   3. pin the nri-bundle chart version in chart-versions.auto.tfvars (once)
#   4. terraform plan: kps updated in place (remote write + keep-list), newrelic created
#   5. apply, then prove: agent pods Running, remote write SUCCEEDING (Prometheus's own
#      counters), and what to type into New Relic to see your metric
#
#   ./scripts/171-newrelic-up.sh            all of it
#   ./scripts/171-newrelic-up.sh --status   the proofs only (every morning, if you like)
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"; TFV="$LAB_ROOT/infra/local/chart-versions.auto.tfvars"
NR_CHART_VERSION="${NR_CHART_VERSION:-8.0.24}"      # nri-bundle, verified 11 Sep 2026 (artifacthub)
NR_NS=newrelic

status() {
  step "New Relic agents (namespace $NR_NS)"
  k get pods -n "$NR_NS" --no-headers 2>/dev/null | awk '{printf "  %-55s %-8s %s restarts\n",$1,$3,$4}' || say "  (none)"
  NR=$(k get pods -n "$NR_NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
  (( NR == 0 )) && ok "every agent pod Running" || warn "$NR pod(s) not Running — kubectl -n newrelic describe pod <name>; a bad key shows as CrashLoopBackOff with 'license' in the log"
  step "Remote write — Prometheus's own counters (the proof the PDF's UI check cannot give)"
  # samples that reached New Relic vs samples that failed, cumulative, from this Prometheus
  OKS=$(promql 'sum(prometheus_remote_storage_samples_total{url=~".*newrelic.*"})' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}' 2>/dev/null || echo "n/a")
  FAIL=$(promql 'sum(prometheus_remote_storage_samples_failed_total{url=~".*newrelic.*"})' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}' 2>/dev/null || echo "n/a")
  PEND=$(promql 'sum(prometheus_remote_storage_samples_pending{url=~".*newrelic.*"})' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}' 2>/dev/null || echo "n/a")
  RATE=$(promql 'sum(rate(prometheus_remote_storage_samples_total{url=~".*newrelic.*"}[5m]))' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.1f}' 2>/dev/null || echo "n/a")
  say "  succeeded $OKS   failed $FAIL   pending $PEND   rate ${RATE}/s (5m)"
  if [[ "$OKS" =~ ^[0-9]+$ ]] && (( OKS > 0 )); then ok "samples are landing in New Relic (${RATE}/s — the keep-list at work: tens of thousands/s without it)"
  else warn "nothing succeeded yet — right after apply give it two minutes; then: kubectl -n monitoring logs sts/prometheus-kps-kube-prometheus-stack-prometheus -c prometheus | grep -i 'remote'"; fi
  SER=$(promql 'count({__name__=~"activation_.*|egift_.*|settlement_.*|.*:health_score|activation:.*|platform:.*"})' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}' 2>/dev/null || echo "?")
  say "  series matching the keep-list right now: $SER (of $(promql 'count({__name__=~".+"})' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}' 2>/dev/null || echo '?') in Prometheus)"
  step "In New Relic (one.newrelic.com)"
  say "  Kubernetes -> cluster 'bhn-sim': nodes, namespaces, workloads — Grafana's cluster, someone else's opinionated UI"
  say "  Query your data (NRQL):"
  say "    FROM Metric SELECT rate(sum(activation_requests_total), 1 minute) WHERE status = 'error' TIMESERIES"
  say "    FROM Metric SELECT latest(activation:health_score), latest(platform:health_score) TIMESERIES"
  say "    FROM Log SELECT count(*) WHERE app.service = 'activation' FACET app.reason SINCE 30 minutes ago"
}
[[ "${1:-}" == --status ]] && { status; exit 0; }

step "1/5  Namespace $NR_NS (Terraform, targeted)"
"$TF" apply -input=false -auto-approve -target=kubernetes_namespace.newrelic >/dev/null 2>&1 || die "targeted apply failed — ./infra/local/tf.sh plan"
ok "namespace $NR_NS (owned by infra/local/namespaces.tf)"

step "2/5  License key"
if k get secret newrelic-license -n "$NR_NS" >/dev/null 2>&1 && k get secret newrelic-license -n "$MONITORING_NS" >/dev/null 2>&1; then ok "secret/newrelic-license present in $NR_NS and $MONITORING_NS"
else "$LAB_ROOT/scripts/170-newrelic-secret.sh" || die "no license key stored"; fi

step "3/5  Pin nri-bundle $NR_CHART_VERSION in chart-versions.auto.tfvars"
if grep -qE '^\s*"newrelic"\s*=' "$TFV"; then ok "already pinned: $(grep -E '^\s*"newrelic"\s*=' "$TFV" | tr -s ' ')"
else
  python3 - "$TFV" "$NR_CHART_VERSION" <<'PY'
import sys,re
p,v=sys.argv[1],sys.argv[2]; s=open(p).read()
s=re.sub(r'\n}\s*$', '\n  "newrelic" = "%s"   # nri-bundle, Day 17 (pinned by hand: not installed by helm first, so 130 never saw it)\n}\n' % v, s)
open(p,'w').write(s)
PY
  ok "pinned (committed with the rest — the version is code)"
fi

step "4/5  terraform plan — infra/local (expect: kps updated in place, newrelic created)"
RC=0; "$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1 || RC=$?
grep -E '^\s+# (kubernetes_namespace|helm_release)\.[a-z_]+ (will be|must be)' infra/local/plan.txt | sed 's/^\s*# /  /'
grep -E '^Plan:' infra/local/plan.txt | sed 's/^/  /'
case $RC in 0) ok "no changes (already applied)";; 2) ;; *) tail -15 infra/local/plan.txt; die "plan failed";; esac
grep -q 'helm_release.kps must be replaced' infra/local/plan.txt && die "the plan REPLACES kps — stop; that is not an overlay change. ./infra/local/tf.sh plan and read it"

if (( RC == 2 )); then
  step "5/5  terraform apply (kps upgrade ~2 min — Prometheus restarts to pick up remote write; the bundle ~2 min)"
  T0=$(date +%s)
  "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1 || { grep -E '^\s*(│ )?Error' -A6 infra/local/apply.txt | head -20; die "apply failed — infra/local/apply.txt (an 'inconsistent result after apply' on kps: Day 13's ghost; re-plan, and untaint if it wants to replace)"; }
  grep -E '^Apply complete' infra/local/apply.txt | sed 's/^/  /'
  ok "applied in $(( ($(date +%s) - T0) / 60 )) min"
  k rollout status -n "$MONITORING_NS" sts/prometheus-kps-kube-prometheus-stack-prometheus --timeout=180s >/dev/null 2>&1 && ok "Prometheus back with remote write configured" || warn "Prometheus still rolling — status in a minute"
  # Grafana's pod may have been replaced by the kps upgrade → tokens gone (Day 13 lesson)
  "$LAB_ROOT/scripts/100-enrich-config.sh" --check >/dev/null 2>&1 || { warn "collectors degraded after the upgrade — re-minting tokens (Day 13 lesson)"; "$LAB_ROOT/scripts/100-enrich-config.sh" >/dev/null 2>&1; "$LAB_ROOT/scripts/120-remediator-config.sh" >/dev/null 2>&1; }
  sleep 60
fi
status
date -u +%FT%TZ > "$CHECKPOINTS/day17-newrelic-applied.txt"
ok "Next: the dashboard + alert in New Relic's UI (DAY17.md Step 3), then ./scripts/172-kb.sh"
