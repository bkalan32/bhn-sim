#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 18 exit criteria"
require_cluster

# Part A — the audit, applied and verified
[[ -f docs/alert-audit.md ]] && grep -qE '^\| `ActivationHighErrorRate` \|' docs/alert-audit.md && t_ok "docs/alert-audit.md: table filled (180)" || t_fail "docs/alert-audit.md table not filled — ./scripts/180-alert-audit.sh"
N=$(grep -cE '^\*\*A[1-6] — ' docs/alert-audit.md 2>/dev/null || echo 0); (( N >= 6 )) && t_ok "six recorded decisions with reasons" || t_fail "alert-audit.md: $N of 6 decisions"
grep -q 'ActivationLatencyBudgetBurn' k8s/alerts.yaml && ! grep -q 'alert: ActivationHighLatency' k8s/alerts.yaml && t_ok "alerts.yaml: static latency alert -> latency SLO burn" || t_fail "alerts.yaml: ActivationHighLatency still there / no LatencyBudgetBurn"
python3 - <<'PY' && t_ok "alerts.yaml: BurnFast has no for: (A3)" || t_fail "ActivationErrorBudgetBurnFast still has a for:"
import yaml,sys
d=yaml.safe_load(open("k8s/alerts.yaml"))
r=[r for g in d["spec"]["groups"] for r in g["rules"] if r.get("alert")=="ActivationErrorBudgetBurnFast"][0]
sys.exit(1 if "for" in r else 0)
PY
grep -q 'PlatformPodRestarting' k8s/alerts.yaml && t_ok "alerts.yaml: PlatformPodRestarting (Day 14's missing alert)" || t_fail "no PlatformPodRestarting rule"
grep -q 'severity =~ "info|none"' k8s/kps-values.yaml && grep -q '|platform"' k8s/kps-values.yaml && t_ok "kps-values.yaml: null routes above the ticket route; platform routed to the bot" || t_fail "kps-values.yaml routing not updated"
grep -qE '^kubeScheduler:' k8s/kps-values.yaml && t_ok "kps-values.yaml: kind's unscrapeable components switched off (A1)" || t_fail "kubeScheduler/etc scrapes still on"
RULES=$(k get --raw "/api/v1/namespaces/${MONITORING_NS}/services/$(prom_svc):9090/proxy/api/v1/rules?type=alert" 2>/dev/null | python3 -c 'import json,sys; print(" ".join(r["name"] for g in json.load(sys.stdin)["data"]["groups"] for r in g["rules"] if r.get("type")=="alerting"))' 2>/dev/null)
grep -qw PlatformPodRestarting <<<"$RULES" && ! grep -qw ActivationHighLatency <<<"$RULES" && t_ok "Prometheus runs the Day 18 rules" || t_fail "Prometheus rules not updated (181)"
grep -qwE "KubeSchedulerDown|KubeSchedulerInstanceUnreachable" <<<"$RULES" && t_fail "KubeScheduler(Down|InstanceUnreachable) still exists — the scrape switch did not apply (181 / terraform)" || t_ok "the permanent kind false positives are gone (no KubeScheduler* rule)"
RC=0; ./infra/local/tf.sh plan -detailed-exitcode >/dev/null 2>&1 || RC=$?; (( RC == 0 )) && t_ok "infra/local plan clean (routing is code)" || t_fail "infra/local plan exit $RC"
AM=$(k get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
R=$(k exec -n "$MONITORING_NS" "$AM" -c alertmanager -- amtool --alertmanager.url=http://localhost:9093 config routes test alertname=CPUThrottlingHigh severity=info service=activation 2>/dev/null | tail -1)
[[ "$R" == null ]] && t_ok "amtool: a demoted alert with a service label still goes to null" || t_fail "amtool route test: CPUThrottlingHigh{info,service=activation} -> '$R' (expected null)"
grep -qE '^\| 12 dry route tests \| (ok|12|pass)' docs/alert-audit.md && t_ok "verification table filled" || warn "docs/alert-audit.md verification table: fill the four rows from 181's output"
grep -q 'startupProbe' k8s/incident-bot.yaml && t_ok "incident-bot: startupProbe (B10's lesson)" || t_fail "no startupProbe on the bot"
grep -q '"bot-down"' services/remediator/signatures.py && t_ok "remediator: IncidentBotDown -> tier-1 restart signature" || t_fail "no bot-down signature"
grep -q 'every page must be actionable and urgent' README.md && t_ok "README: the page rule" || t_fail "README lacks the page = actionable + urgent rule"

# Part B — KPIs
grep -q '## The KPI set (Day 18)' docs/ops-kpis.md && grep -cE '^\| [1-7] \| \*\*' docs/ops-kpis.md | grep -qx 7 && t_ok "docs/ops-kpis.md: seven KPIs defined with sources" || t_fail "docs/ops-kpis.md: the KPI set section / seven rows"
grep -qE '^\| MTTD \(fault' docs/ops-kpis.md && t_ok "KPI current values written (182)" || t_fail "run ./scripts/182-kpis.sh"
python3 -c "import json; d=json.load(open('dashboards/overview.json')); assert sum(1 for p in d['panels'] if 'budget left' in p.get('title','') or 'Remediated' in p.get('title','') or 'Incidents opened' in p.get('title',''))>=4" 2>/dev/null && t_ok "overview dashboard: the queryable KPIs" || t_fail "dashboards/overview.json has no KPI row"
M=$(promql 'count(incidents_created_total{service!=""})' | python3 tools/promjson.py value '{:.0f}' 2>/dev/null || echo 0)
[[ "$M" =~ ^[0-9]+$ ]] && (( M >= 1 )) && t_ok "the bot's counter carries service (the Day 18 build is deployed)" || t_fail "incidents_created_total has no service label yet — deploy the bot, open one incident"

# Part C — the daily report
[[ -f tools/daily_report.py ]] && python3 -m py_compile tools/daily_report.py 2>/dev/null && t_ok "tools/daily_report.py" || t_fail "tools/daily_report.py missing/broken"
bot_get /reports | python3 -c 'import json,sys; sys.exit(0 if len(json.load(sys.stdin))>=1 else 1)' 2>/dev/null && t_ok "the bot stores reports (/reports has entries)" || t_fail "no reports on the bot — python3 tools/daily_report.py"
N=$(ls reports/daily/*.md 2>/dev/null | wc -l); (( N >= 3 )) && t_ok "reports/daily: $N reports (quiet, after-drill, scheduled)" || t_fail "reports/daily has $N of 3 (quiet / after a drill / the Jenkins run)"
OVER=$(grep -hoE '· [0-9]+ words' reports/daily/*.md 2>/dev/null | awk '{if ($2+0>250) n++} END {print n+0}'); (( OVER == 0 )) && t_ok "every report under the 250-word cap" || t_fail "$OVER report(s) over the cap"
grep -lE 'numbers not traceable to the data: none' reports/daily/*.md >/dev/null 2>&1 && t_ok "at least one report with every number traceable (the script's check)" || warn "no report passed the traceability check cleanly — read the 'numbers not traceable' lines"
T=$(grep -l 'TRUNCATED' reports/daily/*.md 2>/dev/null | grep -vc 'truncated' || true); (( T == 0 )) && t_ok "no truncated report kept as current (a cut-off brief looks complete: Eval 9 finding 1)" || t_fail "$T report(s) truncated — re-run them"
CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/job/daily-ops-report/ 2>/dev/null || echo 000)
[[ "$CODE" == 200 || "$CODE" == 403 ]] && t_ok "Jenkins job daily-ops-report exists (H 7 * * *)" || t_fail "no daily-ops-report job (HTTP $CODE) — ./scripts/183-daily-report-job.sh"
grep -q 'Eval 9' docs/ai-eval.md && ! grep -qE '^\| words \(cap 250\) \| _…_' docs/ai-eval.md && t_ok "ai-eval Eval 9 graded" || t_fail "docs/ai-eval.md Eval 9 not graded (three reports)"
git status --porcelain 2>/dev/null | grep -c . >/dev/null && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 18 done." || { warn "Not done yet."; exit 1; }
