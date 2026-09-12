# Day 18 — Alert Hygiene, the KPI Set, and the Daily Ops Report

Adapted from `day18alerthygienekpisdailyreport.pdf`. Changes in **[CORRECTIONS-DAY18.md](CORRECTIONS-DAY18.md)**.

> Everything on kind; no AWS spend. The PDF's audit is a table you fill from memory; ours is
> filled from data (hours each alert has fired in ten days, tickets it produced) with the
> verdicts recorded next to the evidence. Its routing fix is moot here — Day 8 already sends
> everything without a service label to null — so the real hygiene work is in *our* rules,
> and four of the findings are yesterday's: the fast burn that fired after the fix, the bot
> alert delivered to the bot, Prometheus's 47 unnoticed restarts, and a pod killed for
> starting slowly. The report runs on Jenkins at 07:00 and plans for drift itself.

---

## What we're building today, and why — read this first

**Part A — every alert, interrogated.** An alert is a promise: *when this fires, a person
should do something, now.* Eighteen days in, the cluster carries fifteen rules you wrote and
a hundred-odd the chart shipped, and some of them have been red since Day 1 for components
kind cannot expose. That is how fatigue starts: not with one bad alert but with a wall of
them that trains you to stop reading — Day 14's scheduler with 70 real restarts sat behind
a fake "SchedulerDown" for a week. Today each rule answers four questions (actionable?
urgent? symptom or cause? has it ever fired usefully?) next to two numbers only a platform
with history can give, and the verdicts become code: rules via kubectl, routing and scrape
switches via Terraform, proven by asking Alertmanager itself (`amtool`) which receiver each
label set reaches. The sentence for the README: **every page must be actionable and urgent;
everything else is a ticket or a graph.**

**Part B — seven numbers a team can discuss.** `docs/ops-kpis.md` has forty columns of raw
material. A team does not discuss forty columns; it discusses a handful whose definitions it
agreed on. MTTD, MTTR, incidents per week by service, the share the platform remediated
itself, error budget remaining for both SLOs, alert precision, deploy frequency and failure
rate — each defined *exactly* (what counts, what is excluded, why), each with a source, the
queryable four on the overview dashboard, the rest computed from the records.

**Part C — the platform briefs you.** Days 9–11 were the AI on an *event*. This is the AI
on a *schedule*: every morning, gather (the same read-only collectors), constrain (a tight
brief, "no data" is a value, 250 words, the cap stated last), draft (one call), store (on
the bot, next to the incidents it summarises). The hard property is not quality; it is
proportion — a daily brief that exaggerates is ignored by week two, taking the real risks
down with it. So Eval 9 grades three reports for traceability and for *a boring day reading
boring*. Event-driven plus scheduled is the complete shape of AI ops orchestration; both are
now small enough to read in one sitting.

Budget: ~3.5 h (A ~1.5, B ~0.5, C ~1.5). Cost: $0 AWS; three or four model calls.

---

## Before you start

`docs/morning.md`. Then today's files:

```bash
cd ~ && rm -rf /tmp/day18 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day18.zip').extractall('/tmp/day18')"
cp -r /tmp/day18/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh && cd ~/bhn-sim && git status --short | wc -l
```

Load generators on (terminals 2/3) — the audit's "hours firing" and the KPIs read live data,
and Part C's second report follows a drill.

## Part A · Step 1 — Inventory and interrogate (terminal 1)

```bash
./scripts/180-alert-audit.sh
sed -n '/audit:start/,/audit:end/p' docs/alert-audit.md | head -40
```

Every alerting rule Prometheus holds, ours first, then the chart's that fired, ticketed, or
have a known verdict; `h firing (10d)` from Prometheus's own `ALERTS` series, `tickets` from
the bot's records. The four judgment columns come from a map in the script — **read them,
and where you disagree, edit the map, re-run**. Then read the six decisions under the table
(A1–A6); each names its reason, because that is what the next person needs.

## Part A · Step 2 — Act on it, and prove the routing

```bash
./scripts/181-alert-routing.sh
```

Four things, in order. The rules (`k8s/alerts.yaml`, kubectl): the static latency alert is
gone and a latency-SLO burn takes its place; the fast burn loses its `for:`; a
`PlatformPodRestarting` rule appears. The routing and the chart's scrape switches
(`k8s/kps-values.yaml`, Terraform — expect kps *updated in place*): explicit null routes
above the ticket route, `platform` added to the ticket route, kind's four unscrapeable
components switched off. Then `amtool` inside the Alertmanager container: twelve dry
`config routes test` lines — including the trap, a demoted alert that also carries a
`service` label — and two live synthetics: `RoutingProbe{service=smoke-test}` must become a
ticket, `CPUThrottlingHigh{severity=info}` must not. Both expire in two minutes; the probe
ticket resolves itself and is the day's routing-verification record. Fill the four rows of
the verification table at the bottom of `docs/alert-audit.md` from the output.

The bot and the remediator changed too (a startup probe and the `/reports` store and a
per-service counter; a tier-1 restart signature for `IncidentBotDown`). They ship the only
way services ship:

```bash
git add -A && git commit -m "Day 18: alert audit applied — rules, routing, scrape switches; bot startupProbe + /reports; remediator bot-down signature"
```

Jenkins → **deploy-service** → `SERVICE=incident-bot`, change cause `Day 18: startupProbe, /reports, per-service counter` → Build.
Then **deploy-service** → `SERVICE=remediator`, change cause `Day 18: IncidentBotDown tier-1 restart` → Build.
(Watch the bot's rollout this time: the startup probe is what B10 lacked.)

## Part B · Step 3 — The seven KPIs

```bash
./scripts/182-kpis.sh          # asks for the Jenkins password once, for the deploy KPI (Enter to skip)
```

Definitions and sources are already in `docs/ops-kpis.md` → *The KPI set*; the script
writes the current values under them and re-renders the overview dashboard, which now ends
with a KPI row (both error budgets, incidents by service, remediated share, alerts firing,
platform restarts). Read the *Alert precision* line: the noise list next to it is what the
audit just removed from the denominator — the honest way that number goes up.

## Part C · Step 4 — The daily report, three times

```bash
python3 tools/daily_report.py --dry | head -60      # what the model will be given — read it first
python3 tools/daily_report.py                       # run 1: a quiet platform (loadgens on, nothing injected)
```

The report prints, then a line: words against the cap, latency, and **numbers not
traceable to the data** (the script checks every number in the text against the JSON it
sent). The file is `reports/daily/<today>.md` with the data appended; the same text is on
the bot at `/reports/<today>`. Now the after-a-drill run:

```bash
./scripts/102-drill-a.sh 60                          # ~8 min incl. resolve
python3 tools/daily_report.py --day $(date -u +%F)-drill
```

Then the scheduled one — the Jenkins job, created and run once now, registered for 07:00:

```bash
git add -A && git commit -m "Day 18: KPIs, daily report"       # the job clones /repo: commit first
./scripts/183-daily-report-job.sh                                # asks for the Jenkins password
```

It plans for drift first (90 s), gathers, drafts, stores on the bot, archives; the script
then fetches that report into `reports/daily/`. Tomorrow morning's `morning.md` step 4
fetches the 07:00 one — if the laptop was awake.

## Part C · Step 5 — Read the three critically

`docs/ai-eval.md` → **Eval 9**: a row per question, a column per report. The questions that
matter most: is every number in the appendix; are RISKS proportionate (a *resolved* drill is
history, not a risk; "none" on a quiet day is the correct answer); does "no data" survive as
"no data"; and does the quiet report read quiet. Then:

```bash
git add -A && git commit -m "Day 18: alert hygiene, KPI set, daily ops report on a schedule (Eval 9)"
./scripts/188-checkpoint-day18.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `180`: "cannot read Prometheus rules" | the API proxy: `./scripts/up.sh` first; the same path 171/178 use |
| `181`: plan wants to *replace* kps | stop; read `infra/local/plan.txt`. An in-place update is expected (routing + four `enabled: false`) |
| `181`: "inconsistent result after apply" | Day 13's ghost: `cd infra/local && terraform untaint helm_release.kps && cd ../.. && ./scripts/181-alert-routing.sh` |
| `181`: routes do not show `platform` after a minute | the operator rewrites the Alertmanager secret; `kubectl -n monitoring logs sts/alertmanager-kps-kube-prometheus-stack-alertmanager -c config-reloader --tail=5`; then `181 --verify` |
| `181`: a demoted alert reached the bot | route **order**: the null routes must sit above the ticket route; `continue: false` (the default) stops fall-through — that is INC-0020 if it happened live |
| `KubeSchedulerDown` still in the rules after apply | Prometheus reloads rule files on a delay (~1 min); also `kubectl -n monitoring get servicemonitor \| grep scheduler` must be empty |
| bot rollout slow/killed again | `kubectl -n payments describe pod -l app=incident-bot \| grep -A3 Startup` — the startup probe allows 2 min; if it still fails the app is not binding: `logs --previous` |
| `182`: deploy KPI says *no data* | Jenkins needs auth — `JENKINS_USER=admin JENKINS_PASS=… ./scripts/182-kpis.sh` |
| `182`: precision looks wrong | read the *noise* list next to it: names that fired and never ticketed. If a real alert is in it, that is an audit finding, not a KPI bug |
| `daily_report.py`: "no API key" | `./scripts/90-ai-secret.sh`, or `ANTHROPIC_API_KEY` in the environment |
| report over 250 words | `MAX_TOKENS` down in the script (520 → 450) — the cap is already the last line of the prompt |
| report cites a number the check flags | read it: a derived number (a sum, a delta the model computed) is a rule violation — grade it as such in Eval 9 |
| `183`: job fails at Drift | `TF_STATE_PATH` in the container is `/repo/infra/local/terraform.tfstate` — the Day 13 bind mount; `./scripts/133-drift-check-job.sh` proves that path |
| `183`: job fails at Report with `ModuleNotFoundError: copilot` | the job runs the *committed* tree (`git clone /repo`); commit `tools/` |
| `--fetch` 404 in the morning | the 07:00 run never happened (laptop asleep); `python3 tools/daily_report.py` runs it now, and the missing brief is itself the finding |

---

## What's next

Day 19: the final exam. EKS comes back for a day, the whole stack — bot, remediator, copilot,
KB, the daily report — against a three-fault surprise scenario in the cloud, destroyed by
dinner. Carry-over: the CloudWatch collector for the bot; the alert-hygiene findings from
tomorrow's cloud run.
