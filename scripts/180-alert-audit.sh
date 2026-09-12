#!/usr/bin/env bash
# Day 18, Part A, Step 1 — inventory every alert rule and interrogate it WITH DATA.
#
#   ./scripts/180-alert-audit.sh            fill the table in docs/alert-audit.md (between the markers)
#   ./scripts/180-alert-audit.sh --print    just print it
#
# For every alerting rule Prometheus holds (ours + kube-prometheus-stack's defaults):
#   hours firing (10d)   from ALERTS{alertstate="firing"} — how much of the last ten days it was red
#   tickets              incidents on the bot whose alert list contains it (Days 8–17 of history)
#   actionable / urgent / symptom-or-cause / verdict   the four questions, pre-answered for
#                        the rules we know (ours, and the defaults every kind cluster grows);
#                        "?" where you have to decide — the PDF's exercise, with evidence next to it
# The verdicts drive k8s/alerts.yaml and k8s/kps-values.yaml (181 applies + verifies).
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
require_cluster
step "Alert rules in Prometheus (ours + the chart's)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
k get --raw "/api/v1/namespaces/${MONITORING_NS}/services/$(prom_svc):9090/proxy/api/v1/rules?type=alert" > "$T/rules.json" 2>/dev/null || die "cannot read Prometheus rules through the API proxy"
promql 'sum by (alertname) (count_over_time(ALERTS{alertstate="firing"}[10d])) * 30 / 3600' > "$T/firing.json"
bot_get /incidents > "$T/incs.json"; [[ -s "$T/incs.json" ]] || die "the bot is not answering"
python3 - "$T/rules.json" "$T/firing.json" "$T/incs.json" "${1:-}" <<'PY'
import json, sys, re, collections
rules, firing, incs = [json.load(open(sys.argv[i])) for i in (1, 2, 3)]
mode = sys.argv[4]
hours = {r["metric"]["alertname"]: float(r["value"][1]) for r in firing.get("data", {}).get("result", [])}
tickets = collections.Counter()
for i in incs:
    for a in i.get("alerts", []):
        tickets[a] += 1
# ---- the judgment map: actionable?, urgent?, symptom|cause, verdict, why ----------------
OURS = {
 "ActivationHighErrorRate":      ("yes","page","symptom","keep — page", "every drill: 2m40s-2m59s TTD; the catastrophe alert; overlaps BurnFast on purpose (belt and braces)"),
 "ActivationErrorBudgetBurnFast":("yes","page","symptom","keep — page, drop `for:`", "fired AFTER the fix twice on Day 17 (long window + for: 2m); the two windows are the persistence"),
 "ActivationErrorBudgetBurnSlow":("yes","ticket","symptom","keep — ticket", "the slow bleed; has never fired (no slow bleed injected yet)"),
 "ActivationHighLatency":        ("no","—","symptom-ish","REMOVE → latency SLO burn", "fired in every fraud drill at p95 0.48 s while the error alert already said everything; static threshold"),
 "ActivationLatencyBudgetBurn":  ("yes","ticket","symptom","new — ticket", "replaces HighLatency: 99 % < 300 ms budget, two windows, warning"),
 "ActivationNoTraffic":          ("yes","ticket","symptom","keep — ticket", "the Day 2 blind spot; fires when the loadgen dies (a real thing on a laptop)"),
 "SettlementStale":              ("yes","page","symptom","keep — page", "absence alert; INC-0005/0013/0017 detected by it or its siblings"),
 "SettlementZeroRecords":        ("yes","page","symptom","keep — page", "the silent failure (INC-0005, INC-0017)"),
 "SettlementJobFailed":          ("yes","ticket","cause","keep — ticket + tier-1 retry", "INC-0013; the remediator re-runs it"),
 "EgiftHighErrorRate":           ("yes","page","symptom","keep — page", "INC-0016 (game day)"),
 "EgiftHighLatency":             ("yes","ticket","symptom","keep — ticket", "2 s over 5 m is not a static-500ms trap; StepSlow names the culprit"),
 "EgiftStepSlow":                ("yes","ticket","cause","keep — ticket", "names the step; the Day 4 per-step histogram exists for this"),
 "IncidentBotDown":              ("yes","page","symptom","keep — page + tier-1 restart", "was delivered only to the bot (B10's 20 min, no ticket); the remediator now restarts it"),
 "RemediatorDown":               ("yes","ticket","symptom","keep — ticket", "monitor of the second monitor"),
 "PaymentsPodCrashLooping":      ("yes","ticket","cause","keep — ticket + tier-1", "INC-0012; the one cause-level alert that is always actionable"),
 "PlatformPodRestarting":        ("yes","ticket","cause","new — ticket", "Day 14's 70 scheduler / 112 collector restarts and Day 17's 47 Prometheus restarts, unalerted for a week+"),
}
DEFAULTS = {
 "Watchdog":                     ("no","—","meta","null (Day 8)", "must fire forever: it is the heartbeat"),
 "InfoInhibitor":                ("no","—","meta","null (severity=info)", "chart plumbing for inhibition"),
 "KubeSchedulerDown":            ("no","—","cause","REMOVE the scrape (kind: 127.0.0.1)", "fired since Day 1 for a scheduler that was fine; hid its 70 real restarts (0017-b)"),
 "KubeControllerManagerDown":    ("no","—","cause","REMOVE the scrape (kind: 127.0.0.1)", "same: unscrapeable on kind, permanent false positive"),
 "KubeProxyDown":                ("no","—","cause","REMOVE the scrape (kind)", "same"),
 "KubeSchedulerInstanceUnreachable":        ("no","—","cause","REMOVE the scrape (kind: 127.0.0.1)", "this chart's name for it: pending 28 h in 10 d for a scheduler that was fine; hid its 70 real restarts (0017-b)"),
 "KubeControllerManagerInstanceUnreachable":("no","—","cause","REMOVE the scrape (kind: 127.0.0.1)", "same: unscrapeable on kind"),
 "KubeProxyInstanceUnreachable":            ("no","—","cause","REMOVE the scrape (kind)", "same"),
 "KubeAPIErrorBudgetBurn":       ("yes","ticket","symptom","KEEP — the one real alert in the noise pile", "the API server's own SLO burn; its 13.8 h firing in 10 d are Day 14's VM starvation (0017-a) — nobody read it because it sat next to the fakes"),
 "KubeAPIDown":                  ("yes","page","symptom","keep — page", "if true, nothing else works"),
 "etcdMembersDown":              ("no","—","cause","REMOVE the scrape (kind)", "etcd metrics bound to localhost on kind"),
 "etcdInsufficientMembers":      ("no","—","cause","REMOVE the scrape (kind)", "same"),
 "TargetDown":                   ("sometimes","ticket","cause","null unless it names OUR job", "on kind it is the three unscrapeable components; our services have their own Down alerts"),
 "CPUThrottlingHigh":            ("no","—","cause","null (routed)", "we set requests low on purpose; throttling is the budget working, not a fault"),
 "KubeMemoryOvercommit":         ("no","—","cause","null (routed)", "one node; overcommit is the lab's shape"),
 "KubeCPUOvercommit":            ("no","—","cause","null (routed)", "same"),
 "KubePodCrashLooping":          ("yes","ticket","cause","keep for platform ns; PaymentsPodCrashLooping covers payments", "for: 15m and no service label — ours is the faster copy for payments"),
 "KubeDeploymentReplicasMismatch":("yes","ticket","symptom","keep (dashboard)", "true during every rollout; useful only if it persists"),
 "KubeContainerWaiting":         ("sometimes","ticket","symptom","keep (dashboard)", "ImagePullBackOff shows here"),
 "KubeJobFailed":                ("yes","ticket","symptom","keep; SettlementJobFailed is the actionable copy", "never resolves on its own (Day 5 B-fix in ours)"),
 "KubeJobNotCompleted":          ("sometimes","ticket","symptom","keep (dashboard)", "12h threshold — settlement runs in seconds"),
 "PrometheusRuleFailures":       ("yes","ticket","cause","keep — ticket", "a broken rule file is a silent blind spot; this is the alert for Day 3's YAML fault"),
 "PrometheusNotConnectedToAlertmanagers":("yes","page","cause","keep — page", "no alert can page if this is true"),
 "AlertmanagerFailedReload":     ("yes","ticket","cause","keep — ticket", "a bad kps-values routing change shows here first"),
 "PrometheusTargetSyncFailure":  ("yes","ticket","cause","keep — ticket", ""),
 "KubePersistentVolumeFillingUp":("yes","ticket","symptom","keep — ticket", "the bot's PVC"),
 "NodeClockNotSynchronising":    ("no","—","cause","null (routed)", "WSL's clock drifts after sleep; not a platform fault"),
 "AlertmanagerFailedToSendAlerts":        ("yes","page","symptom","KEEP — page (the ticket layer's own alarm)", "36 min firing in 10 d = Day 17's bot outage, seen from Alertmanager — went to null; IncidentBotDown's cousin, now the remediator restarts the bot"),
 "AlertmanagerClusterFailedToSendAlerts": ("yes","page","symptom","KEEP — page (same event, cluster-wide form)", "same 36 min; one-replica Alertmanager, so 'cluster' = the one"),
 "AlertmanagerClusterCrashlooping":       ("yes","ticket","cause","keep — ticket; PlatformPodRestarting covers it now", "7.6 h in 10 d: the kps upgrades (Days 13/17) and Day 14's starvation; restarts of the alerting path must be visible"),
 "KubePodNotReady":                       ("yes","ticket","symptom","keep (dashboard); PaymentsPodCrashLooping is the fast copy for payments", "1.9 h = the bot's build 34 crash-loop; for: 15m is too slow to page on"),
 "KubeDaemonSetRolloutStuck":             ("yes","ticket","symptom","keep (dashboard)", "1.9 h = Fluent Bit / New Relic agents mid-rollout; persists = a real stuck node agent"),
 "NodeSystemSaturation":                  ("yes","ticket","cause","keep — and FIX: it never fired", "0 h in 10 d through load 48 (Day 14) and 68 (Day 17) on 8 CPUs — the one alert for 0017-a, and it cannot fire as written on this node (for: 15m; check its expression against node_load15) — follow-up"),
 "KubeletTooManyPods":           ("no","—","cause","dashboard", "one node, 110 pods; informational"),
}
rows = []
for g in rules.get("data", {}).get("groups", []):
    ours = g.get("file", "").find("payments") >= 0 or g.get("name") in {"activation","activation-slo","settlement","egift","incident-bot","remediation","health-scores","platform-health"}
    for r in g.get("rules", []):
        if r.get("type") != "alerting":
            continue
        n = r["name"]; lab = r.get("labels", {})
        j = OURS.get(n) or DEFAULTS.get(n) or ("?","?","?","? (decide)","")
        rows.append((ours, n, lab.get("severity","-"), lab.get("service","-") if ours else ("service" if "service" in lab else "-"),
                     r.get("duration", 0), r.get("state","-"), hours.get(n, 0.0), tickets.get(n, 0), *j))
rows.sort(key=lambda x: (not x[0], -x[6], x[1]))
mine = [x for x in rows if x[0]]; theirs = [x for x in rows if not x[0]]
loud = [x for x in theirs if x[6] > 0 or x[7] > 0 or x[1] in DEFAULTS]
lines = ["| alert | sev | service | for | state now | h firing (10d) | tickets | actionable? | urgent? | symptom/cause | verdict | why |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
def fmt(x):
    ours, n, sev, svc, dur, st, h, t, a, u, sc, v, why = x
    return f"| `{n}` | {sev} | {svc} | {int(dur)}s | {st} | {h:.1f} | {t} | {a} | {u} | {sc} | **{v}** | {why} |"
lines.append(f"| **ours ({len(mine)})** | | | | | | | | | | | |")
lines += [fmt(x) for x in mine]
lines.append(f"| **kube-prometheus-stack ({len(theirs)} rules; the {len(loud)} that fired, ticketed, or have a known verdict)** | | | | | | | | | | | |")
lines += [fmt(x) for x in loud]
quiet = len(theirs) - len(loud)
lines.append(f"| *{quiet} more chart rules* | | | | 0 firing in 10d, 0 tickets | | | | | | *leave; they are the chart's for a reason (node, kubelet, API server)* | |")
table = "\n".join(lines)
print(f"  ours: {len(mine)} rules   chart: {len(theirs)} rules, {len([x for x in theirs if x[6]>0])} fired in 10d, {sum(x[7] for x in theirs)} became tickets")
print(f"  loudest (h firing / 10d): " + ", ".join(f"{x[1]} {x[6]:.0f}h" for x in sorted(rows, key=lambda x:-x[6])[:6]))
if mode == "--print":
    print(table); sys.exit(0)
import pathlib
p = pathlib.Path("docs/alert-audit.md"); s = p.read_text() if p.exists() else ""
a, b = "<!-- audit:start -->", "<!-- audit:end -->"
if a in s and b in s:
    s = s[:s.index(a)+len(a)] + "\n" + table + "\n" + s[s.index(b):]
    p.write_text(s); print("  docs/alert-audit.md: table filled")
else:
    print(table); print("  (docs/alert-audit.md has no markers — table printed)")
PY
ok "Next: read docs/alert-audit.md, then ./scripts/181-alert-routing.sh"
