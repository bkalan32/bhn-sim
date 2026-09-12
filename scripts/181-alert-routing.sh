#!/usr/bin/env bash
# Day 18, Part A, Step 2 — act on the audit, then PROVE the routing with amtool.
#
#   ./scripts/181-alert-routing.sh            rules (kubectl) + routing/scrapes (Terraform) + amtool verification
#   ./scripts/181-alert-routing.sh --verify   only the amtool part (dry route tests + one live synthetic)
#
# Two layers, two tools, on purpose (Day 3 / Day 13 contract):
#   k8s/alerts.yaml      the PrometheusRule we own  -> kubectl apply   (rules are ours, applied like a manifest)
#   k8s/kps-values.yaml  Alertmanager routing + the chart's scrape switches -> terraform (the platform layer)
# Then amtool, from inside the Alertmanager container:
#   `amtool config routes test` answers "which receiver would THIS label set reach" without
#   sending anything — one line per audit verdict; and one LIVE synthetic alert per receiver
#   proves the bot opens a ticket for what should be a ticket and nothing for what should not.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
require_cluster
TF="$LAB_ROOT/infra/local/tf.sh"
AM_POD=$(k get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "$AM_POD" ]] || die "no alertmanager pod in $MONITORING_NS"
amtool() { k exec -n "$MONITORING_NS" "$AM_POD" -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 "$@"; }

if [[ "${1:-}" != --verify ]]; then
  step "1/4  Rules — k8s/alerts.yaml (HighLatency removed; LatencyBudgetBurn, PlatformPodRestarting added; BurnFast without for:)"
  python3 -c "import yaml,sys; yaml.safe_load(open('k8s/alerts.yaml'))" || die "k8s/alerts.yaml does not parse"
  k apply -f k8s/alerts.yaml >/dev/null && ok "PrometheusRule applied"
  say "  waiting for Prometheus to reload the rule file (~40 s)"
  for _ in $(seq 1 12); do
    sleep 5
    NAMES=$(k get --raw "/api/v1/namespaces/${MONITORING_NS}/services/$(prom_svc):9090/proxy/api/v1/rules?type=alert" 2>/dev/null \
      | python3 -c 'import json,sys; print(" ".join(r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"] if r.get("type")=="alerting"))' 2>/dev/null)
    grep -qw PlatformPodRestarting <<<"$NAMES" && grep -qw ActivationLatencyBudgetBurn <<<"$NAMES" && ! grep -qw ActivationHighLatency <<<"$NAMES" && break
  done
  grep -qw PlatformPodRestarting <<<"$NAMES" && ok "Prometheus has the Day 18 rules" || die "Prometheus did not load the new rules — kubectl -n monitoring logs sts/prometheus-kps-kube-prometheus-stack-prometheus -c config-reloader"
  grep -qw ActivationHighLatency <<<"$NAMES" && warn "ActivationHighLatency still present" || ok "ActivationHighLatency is gone"

  step "2/4  Routing + scrape switches — k8s/kps-values.yaml via Terraform (kps updated in place)"
  RC=0; "$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1 || RC=$?
  case $RC in
    0) ok "plan clean — routing already applied" ;;
    2) grep -E 'will be|must be|Plan:' infra/local/plan.txt | sed 's/^/  /'
       grep -q 'must be replaced' infra/local/plan.txt && die "the plan wants to REPLACE something — stop and read infra/local/plan.txt"
       RC2=0; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1 || RC2=$?
       grep -E '^(helm_release|Apply complete)|Error:' infra/local/apply.txt | sed 's/^/  /'
       (( RC2 == 0 )) || die "apply failed — infra/local/apply.txt (Day 13's 'inconsistent result' → terraform untaint helm_release.kps, re-run)"
       ok "applied" ;;
    *) die "terraform plan failed (exit $RC) — infra/local/plan.txt" ;;
  esac
  say "  waiting for Alertmanager to pick up the new routes (the operator rewrites its secret; ~60 s)"
  for _ in $(seq 1 18); do
    sleep 5
    amtool config routes show 2>/dev/null | grep -q 'platform' && break
  done
  amtool config routes show 2>/dev/null | grep -q 'platform' && ok "Alertmanager routes include the Day 18 changes" || warn "routes do not show 'platform' yet — give it a minute and run: $0 --verify"
  say "  the three unscrapeable kind components: their ServiceMonitors should be gone"
  N=$(k get servicemonitor -n "$MONITORING_NS" 2>/dev/null | grep -cE 'kube-scheduler|kube-controller-manager|kube-etcd|kube-proxy' || true)
  (( N == 0 )) && ok "no ServiceMonitor for scheduler/controller-manager/etcd/kube-proxy (their permanent 'Down' alerts are gone with them)" || warn "$N of those ServiceMonitors still exist — the chart values did not apply?"
fi

step "3/4  amtool: which receiver would each label set reach? (dry — nothing is sent)"
amtool config routes show 2>/dev/null | sed 's/^/  /' | head -20
say ""
t() {  # expect labels...
  local expect="$1"; shift
  local got
  got=$(amtool config routes test "$@" 2>/dev/null | tail -1 | tr -d '\r')
  if [[ "$got" == "$expect" ]]; then ok "$(printf '%-72s -> %s' "$*" "$got")"; else warn "$(printf '%-72s -> %s (expected %s)' "$*" "$got" "$expect")"; return 1; fi
}
FAILS=0
t incident-bot alertname=ActivationHighErrorRate service=activation severity=critical || FAILS=$((FAILS+1))
t incident-bot alertname=ActivationLatencyBudgetBurn service=activation severity=warning slo=latency || FAILS=$((FAILS+1))
t incident-bot alertname=PlatformPodRestarting service=platform severity=warning namespace=monitoring || FAILS=$((FAILS+1))
t incident-bot alertname=IncidentBotDown service=incident-bot severity=critical || FAILS=$((FAILS+1))
t incident-bot alertname=SettlementZeroRecords service=settlement severity=critical || FAILS=$((FAILS+1))
t null alertname=Watchdog severity=none || FAILS=$((FAILS+1))
t null alertname=InfoInhibitor severity=info || FAILS=$((FAILS+1))
t null alertname=CPUThrottlingHigh severity=info namespace=payments container=activation || FAILS=$((FAILS+1))
t null alertname=KubeMemoryOvercommit severity=warning || FAILS=$((FAILS+1))
t null alertname=KubeSchedulerInstanceUnreachable severity=warning || FAILS=$((FAILS+1))
t null alertname=KubePodCrashLooping severity=warning namespace=monitoring pod=x || FAILS=$((FAILS+1))
# the trap the PDF's troubleshooting names: a demoted alert that ALSO carries a service label
t null alertname=CPUThrottlingHigh severity=info service=activation || FAILS=$((FAILS+1))
(( FAILS == 0 )) && ok "every label set reaches the receiver the audit says" || warn "$FAILS route(s) wrong — route ORDER: specific null routes must sit above the ticket route (CORRECTIONS-DAY18)"

step "4/4  One live synthetic per receiver (amtool alert add; both expire in 2 min)"
BEFORE=$(bot_get /incidents | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
END=$(date -u -d '+2 minutes' +%FT%TZ 2>/dev/null || date -u -v+2M +%FT%TZ)
amtool alert add RoutingProbe service=smoke-test severity=warning --annotation=summary="Day 18 routing probe — should become a ticket, resolves itself" --end="$END" >/dev/null && ok "sent RoutingProbe{service=smoke-test}  (expect: a ticket)"
amtool alert add CPUThrottlingHigh severity=info namespace=payments container=probe --annotation=summary="Day 18 routing probe — must NOT become a ticket" --end="$END" >/dev/null && ok "sent CPUThrottlingHigh{severity=info}   (expect: nothing)"
say "  group_wait 15 s + webhook; checking the bot in 40 s"
sleep 40
INCS=$(bot_get /incidents)
python3 - "$INCS" "$BEFORE" <<'PY'
import json, sys
incs, before = json.loads(sys.argv[1]), int(sys.argv[2])
probe = [i for i in incs if "RoutingProbe" in i.get("alerts", [])]
noise = [i for i in incs if "CPUThrottlingHigh" in i.get("alerts", [])]
ok = lambda m: print(f"  ok   {m}"); bad = lambda m: print(f"  FAIL {m}")
(ok if probe else bad)(f"RoutingProbe -> ticket: {probe[0]['id'] if probe else 'NO ticket (the smoke-test route is broken)'}")
(bad if noise else ok)("CPUThrottlingHigh{severity=info} -> " + (f"a ticket ({noise[0]['id']}) — the demotion did NOT hold" if noise else "no ticket (demoted correctly)"))
print(f"  incidents before {before}, after {len(incs)}")
sys.exit(0 if (probe and not noise) else 1)
PY
RC=$?
say "  both synthetics expire at $END; the RoutingProbe ticket resolves itself (send_resolved) — it is the day's routing-verification record"
(( RC == 0 )) && ok "routing verified end to end" || warn "routing verification failed — see above; if a demoted alert ticketed, that is INC-0020 (the PDF says 0019)"
ok "Next: Jenkins deploy-service for incident-bot (startupProbe, /reports, per-service counter) and remediator (bot-down signature); then ./scripts/182-kpis.sh"
