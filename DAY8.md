# Day 8 — Alert Routing and Your Own Incident Bot

Adapted from `day8alertroutingincidentbot.pdf`. Changes in **[CORRECTIONS-DAY8.md](CORRECTIONS-DAY8.md)**.

> The PDF's routing sends Watchdog and nine kube-system false positives to the bot, so
> you'd start the day with ten permanent open incidents. Its severity sub-route splits one
> outage into two tickets, its severity "max" is a string compare that always says
> *warning*, and its `emptyDir` wipes every incident record on every deploy — including the
> two deploys Days 9 and 10 make. All fixed here; the log has the details.

---

## What we're building today, and why — read this before typing anything

**The gap.** For seven days alerts have fired, resolved, and vanished. Alertmanager shows
what is firing *now*; nothing remembers that activation broke at 14:02, that two alerts
belonged to the same outage, or that it was over by 14:11. In a company that memory lives in
a ticketing system (ServiceNow, PagerDuty, Jira). Your ServiceNow PDI is still on the
waitlist, so today you build the ticketing layer yourself — which the PDF rightly says is the
better learning path anyway. Every alert-to-ticket integration you'll ever meet is a
variation of the sixty lines you write today.

**The chain.** Four moving parts, each of which you'll verify on its own before joining it
to the next:

```
Prometheus rule fires  →  Alertmanager groups it  →  webhook POST  →  incident-bot writes a record
        (Day 3)              (config: today)         (JSON, today)       (FastAPI, today)
```

*Alertmanager* has been running since Day 1 with the chart's default config: one `null`
receiver, everything discarded. Today you give it a **route** — rules for *which* alerts go
*where*, and how to batch them — and a **receiver**: a webhook URL. Routing is where alert
fatigue is won or lost, and each setting is a deliberate choice:

| Setting | Ours | Meaning |
|---|---|---|
| `group_by` | `[service]` | alerts with the same service label travel together — **one ticket per service outage** |
| `group_wait` | `15s` | collect related alerts for 15s before the first notification |
| `group_interval` | `2m` | when the group changes (an alert joins or resolves), wait 2m before sending the update |
| `repeat_interval` | `4h` | re-nag about a still-open group every 4h, not every minute |
| `send_resolved` | `true` | tell the webhook when the group clears — this is what lets the bot **auto-close** incidents |

*The incident bot* is a third FastAPI service. It receives the webhook, opens an incident
if none is open for that service, appends every later webhook to an **append-only
timeline**, and marks the incident resolved when Alertmanager says every alert in it has
cleared. It exposes the records over HTTP and its own metrics to Prometheus (**monitor the
monitor**). Records live on a PersistentVolume so they survive the two rebuilds Days 9 and
10 will make.

**Two design decisions you should be able to defend afterwards:**

1. **Join key = service.** Alertmanager's `groupKey` looks like the obvious join, but it
   embeds the *route* that matched — so a critical/warning split puts one outage into two
   groups and two tickets. The bot joins on the service label, tracks every group inside the
   incident, and closes only when *all* groups have resolved. One fault, one ticket, every
   alert inside it.
2. **Default receiver = null.** Only alerts that carry one of *your* service labels become
   tickets. `Watchdog` fires forever by design (it is Alertmanager's heartbeat); the kind
   cluster's scheduler/controller-manager "down" alerts are artefacts. A ticket queue full of
   things nobody will ever act on trains people to ignore the queue.

**Then the backlog.** The week-1 review left two items with "Day 8" against them and the
PDF adds a third. All three ship today, through the pipeline, with change causes:
`SETTLEMENT_STRICT` becomes the default (INC-0005), the amount-mix test stops being
optional (INC-0006), and eGift finally gets latency alerts (INC-0002/3) — because every eGift
incident so far was found by a human looking at a screen.

**Timing to expect** (so you don't think it's broken): an incident *opens* ~2.5 minutes after
a fault (the alert's `for: 2m` + `group_wait`). It *closes* 5–8 minutes after recovery —
the 2m and 5m alert windows must drain, then `group_interval` batches the resolved
notification. Incidents close when the signals clear, not when the fix lands. New on-call
engineers mistake this lag for a broken integration every single time.

---

## Before you start

**Terminal A** (`~/bhn-sim`) — commands. **#2** `12-loadgen.sh`, **#6** `33-loadgen-egift.sh`,
**#3** `06-grafana.sh` — should already be running; if not, `./scripts/up.sh` tells you.

```bash
cd ~/bhn-sim
cp -r /mnt/c/Users/bkala/Downloads/bhn-sim/. ~/bhn-sim/     # the /. is what copies .gitignore
./scripts/up.sh --check
git status                                                  # you should see the Day 8 files as changes
```

Budget: ~2.5 hours, of which ~25 minutes is waiting for alert windows. Coffee goes in the
waits.

---

## Part A — The bot, on its own

**Step 1 — Read the bot.** `services/incident-bot/app.py`, top to bottom. It is 300 lines
because the comments are the lesson. Then `k8s/incident-bot.yaml` — note the PVC and
`strategy: Recreate`, and why.

**Step 2 — Build, deploy, prove it with a fake webhook.**

```bash
./scripts/80-build-incident-bot.sh
```

Runs the bot's unit tests, builds `incident-bot:0.1`, deploys it, then posts a **synthetic**
Alertmanager payload (service `smoke-test`) and a matching *resolved* one, and shows you the
timeline: opened → resolved → duration filled in. Finally it checks Prometheus is scraping
`incidents_open`. Debug one moving part at a time — the bot works before Alertmanager is
anywhere near it.

From now on, any time:

```bash
python3 tools/inc.py list            # one line per incident
python3 tools/inc.py timeline <id>   # human-readable
python3 tools/inc.py show <id>       # the JSON — what Day 9's AI will read
```

No port-forward: it goes through the API server's service proxy, which works wherever
`kubectl` works and survives pod restarts.

---

## Part B — Point Alertmanager at it

**Step 3 — Read the routing.** `k8s/kps-values.yaml`. Twenty lines; every one is an
opinion. Compare it to the PDF's and read B1/B2 in the corrections log.

**Step 4 — Apply it the Helm way, and prove it landed.**

```bash
./scripts/81-alertmanager-route.sh
```

Loads the new alert rules (eGift, IncidentBotDown), then `helm upgrade` **pinned to the
chart version you already run**, then three proofs: the generated secret mentions the bot,
Alertmanager's *live* status page shows the receiver (takes up to 2 min — the config
reloader polls), and a list of what's firing right now and where it routes. Expect
`Watchdog` and the kube-system set under "→ null" — that's correct.

If `EgiftHighLatency` fires and opens an incident within a few minutes, do **not** treat it as
noise. Your Day 7 overview screenshot showed eGift p95 at 2.4s with nothing alerting. This is
backlog #3 closing. Look at it: `python3 tools/inc.py list`, then Grafana's eGift dashboard
step panel — is it `activate` or `send_email`? Note what you find; it goes in the review.

---

## Part C — One real incident, end to end

**Step 5 — The drill.** Overview in Grafana, Alertmanager at :9093 if you like, and:

```bash
./scripts/82-incident-drill.sh
```

`FRAUD_SVC_DOWN=true`, then it *waits and narrates*: error rate to 100% → `ActivationHighErrorRate`
pending → firing → group_wait → **INCIDENT OPENED**, and prints the timeline. Holds four
minutes so `ActivationErrorBudgetBurnFast` joins **the same incident** (that's `group_by:
[service]` at work). Recovers. Waits for the last alert to clear → **INCIDENT RESOLVED**
with `duration_min`.

Two things to notice while it runs. `ActivationHighLatency` never fires — v0.4's fail-fast
keeps p95 at ~0.3s, and now INC-0001's fix is visible *in a ticket*. And the record says
*what* fired and *when*, but not *why*: `fraud_service_timeout` is still only in Splunk.
That's Day 9 and Day 10.

**Step 6 — The overview.** Re-import `dashboards/overview.json` (Dashboards → New → Import
→ upload → **Overwrite**). New bottom row: open incidents, incidents (24h) — a core
operational KPI; teams get judged on its trend — last duration, webhooks delivered, bot
scraped. Open incidents went 0 → 1 → 0 during the drill.

**Step 7 — Write it up.** `incidents/INC-0007.md` is scaffolded with the two lags that
matter (fault → alert, recovery → close). Fill it from `python3 tools/inc.py timeline <id>`.

---

## Part D — Clear the backlog, through the pipeline

**Step 8 — Read the changes.** Four small diffs, all already in the tree:

- `services/settlement/settle.py` + `k8s/settlement.yaml`: `SETTLEMENT_STRICT` defaults to
  **true**, version 0.2. The job refuses to call zero records a success. The alerts stay as
  the backstop — layered defence.
- `services/activation/tests/test_app.py`: the `skipif` gate is gone.
  `test_activate_all_production_amounts` always runs.
- `k8s/alerts.yaml`: `EgiftHighErrorRate`, `EgiftHighLatency`, `EgiftStepSlow` (names the
  slow step), `IncidentBotDown`. Already loaded by Step 4.
- `Jenkinsfile`: `SERVICE` now offers all four workloads. A CronJob is verified by *running a
  job*; a metric-less deployment by staying Ready with zero restarts. Read the `Verify` stage.

**Step 9 — Commit everything from today.**

```bash
git add -A
git status            # sanity: no checkpoints/*.txt, no fluent-bit-values.yaml, no .venv
git commit -m "Day 8: incident bot, Alertmanager routing, settlement strict default, egift alerts, amount test ungated"
```

**Step 10 — Ship through Jenkins.** http://localhost:8081/job/deploy-service

Jenkins reads parameters from the *last* run's Jenkinsfile, so the dropdown still says
`activation | egift`. Run one build first to refresh it:

1. **Build with Parameters** → `SERVICE=activation`, `CHANGE_CAUSE=routine release (Day 8 pipeline refresh)`. Green. Blue line.
2. **Build with Parameters** → `SERVICE=settlement`, `CHANGE_CAUSE=settlement 0.2: refuse success on zero records (INC-0005)`.
   Watch *Verify* create `settlement-ci-<n>`, wait for it, print its log: `settlement complete`, records > 0.
3. **Build with Parameters** → `SERVICE=incident-bot`, `CHANGE_CAUSE=incident-bot 0.1 via pipeline`.
   Tests run in Test. Verify sleeps 30s and checks for restarts. Records survive — check
   `python3 tools/inc.py list` afterwards: INC-0007 is still there. That's the PVC.

**Step 11 — Verify the settlement fix, all three modes** (~8 min, mostly waiting):

```bash
./scripts/83-settlement-strict.sh
```

`silent` now exits 2, the Job goes **Failed**, the log says `refusing to report success`,
and `SettlementJobFailed` + `SettlementZeroRecords` both fire — four signals where Day 5 had
one. `crash` still loud. `none` healthy. Tick the follow-up in `incidents/INC-0005.md` and
add a *fix verified* line with the job name. Optional: `44-settlement-failure.sh lenient`
shows you the Day 5 behaviour again, for contrast, then `none`.

**Step 12 — Prove the test catches the bug** (~1 min):

```bash
./scripts/84-test-catches-bug.sh
```

Throwaway branch, velocity check re-applied, `pytest`: **red at $50 and $100 in seconds**,
before any build. Branch deleted, `main` untouched. On Day 6 this bug ran in production for
two minutes at 67% errors and needed an automated rollback. Tick INC-0006's follow-up with
*fix verified* and the seconds.

---

## Wrap

```bash
git add -A && git commit -m "Day 8: INC-0005/0006 verified, INC-0007 written up"
./scripts/88-checkpoint-day8.sh
```

Twelve checks, including "a resolved activation incident exists with a duration" — the one
sentence that proves the whole chain.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `81` says the secret doesn't mention incident-bot | YAML indentation in `kps-values.yaml`. `helm get values kps -n monitoring` shows what Helm actually received. |
| Alertmanager never reloads | `kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c config-reloader` |
| Drill: alert firing in Prometheus, nothing in the bot | `kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 \| grep -i webhook` — a 5xx from the bot? `kubectl logs -n payments deploy/incident-bot \| python3 tools/logfmt.py` |
| Incident won't close for 10+ minutes | Which alert is still firing? BurnFast needs its 5m window clean. It will close. |
| Ten incidents opened right after `81` | You applied the PDF's routing, not `k8s/kps-values.yaml`. Re-run `81`, then `python3 tools/inc.py delete <id>` each. |
| Jenkins dropdown lacks settlement / incident-bot | Run one build; parameters refresh after it. |
| `53-bad-deploy.sh apply` now fails | Correct — the amount test caught it. `FORCE_BAD_DEPLOY=1` to ship it anyway (Day 10). |
| PVC Pending | `kubectl get storageclass` — `standard` should be default. `kubectl describe pvc incident-bot-data -n payments`. |

---

## What's next

Day 9: when an incident opens or resolves, the bot asks an LLM to draft the internal summary,
the stakeholder update and a post-incident review skeleton — from the timeline you built
today. **The AI drafts; a human decides.** You'll need an Anthropic API key (a few dollars
covers the series) and the records from today's drill.
