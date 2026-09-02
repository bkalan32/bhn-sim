# Day 5 — SLOs, Error Budgets, and the Silent Failure

Adapted from `day5slosandsilentfailure.pdf`. Changes in **[CORRECTIONS-DAY5.md](CORRECTIONS-DAY5.md)**.

> **Timing correction up front.** The PDF says the burn-rate alert fires "after about two
> minutes." It fires after **~40** at the PDF's setting, because it gates on a 1-hour
> average — that's the rule working, not failing. The drill uses a bigger injection so
> you see it in under ten. Arithmetic in `docs/slos.md`.

---

## Where Day 4 left you

Detect a problem, see its shape, find the failing line, pinpoint the slow hop. A complete
diagnostic loop.

What you can't yet answer is a **management** question: *"How reliable is activation,
really?"* Not "is it down right now" but "how much have we let customers down this month,
and how much more can we afford?" That's SLIs, SLOs and error budgets — named explicitly
in the job description.

Then the nastier half: everything so far has been *loud*. Batch jobs fail *quietly*.

---

## Part A — SLOs

### Step 1 — Read `docs/slos.md` first

Deciding is the hard part; the PromQL is easy. Two SLOs: **availability 99.5%** and
**latency 99% under 300ms**, both over 30 days. Read the arithmetic section — it's the
correction to the PDF and it's the thing to understand about long windows.

One finding to internalise: the service's 2% baseline is **4× the budget**. It will never
meet 99.5%. And neither alert fires at 4×, because "over budget" is a planning problem and
"burning fast" is an incident. That gap is deliberate.

### Step 2 — Rules

```bash
./scripts/40-slo-rules.sh
```

Seven recording rules (`activation:sli_availability:ratio_rate5m` and friends — the
community naming convention) plus two burn-rate alerts, straight from the Google SRE
Workbook. The script waits for the rules to produce data and prints your current burn
rate. Expect **~4×**.

### Step 3 — Dashboard

Import `dashboards/activation-slo.json`. **Error budget remaining** is the panel to show a
manager: when it hits zero, the honest engineering answer is "stop shipping features, fix
reliability" — that's the whole point of the model. The **burn rate** time series shows all
three windows; watch how differently they move in the next step.

### Step 4 — Burn it

```bash
./scripts/41-burn-budget.sh
```

Injects `ERROR_RATE=0.50`, prints the ETA (~8.5 min including `for: 2m`), watches the
5m and 1h burn rates and the alert state every 30s, then rolls back and watches it
resolve. **Revert-on-exit is guaranteed** — Ctrl-C mid-drill and it still resets.

Watch the burn-rate panel: the 5m line jumps to ~100× instantly; the 1h line *climbs*.
When both are past 14.4 for two minutes, the page goes out. Read the alert text — it's not
"errors are high," it's "the month is gone in two days."

After rollback the 5m line falls in ~4.5 min and the alert clears **while the 1h line is
still high**. That's what the short window is for.

→ `incidents/INC-0004.md`

---

## Part B — The silent failure

### The business flow

Every night the network reconciles the day's activations against what retailers report and
prepares the money movement. If it doesn't run, **nobody gets paid** and finance notices
days later. No request rate, no latency, no 500s. It ran correctly or it didn't — and "didn't"
can be completely silent.

### Step 5 — Pushgateway

```bash
./scripts/42-install-pushgateway.sh
```

A job that runs 30s and exits is invisible to a scraper on a 15s loop. The Pushgateway is
where short-lived jobs leave their final numbers.

### Step 6 — The job

Read `services/settlement/settle.py`. Look at the `silent` mode: exit 0, "settlement
complete," metrics pushed, zero records. Then:

```bash
./scripts/43-build-settlement.sh
```

Builds it, schedules it every 5 minutes, **runs one immediately** so you don't wait for the
first tick, and confirms the metrics landed in Prometheus.

### Step 7 — Alert on absence, not presence

Already loaded by Step 2 — three rules in the `settlement` group. `SettlementStale` is the
important pattern: **alert when a good thing stops happening**, not only when a bad thing
starts. Every "expected every N minutes" process in a company needs one.

### Step 8 — Three failure modes

Dashboard on screen (the settlement panel is on the SLO dashboard). Then, one at a time:

```bash
./scripts/44-settlement-failure.sh crash
```
Kubernetes: **Failed**. `SettlementJobFailed` fires. Loud.

```bash
./scripts/44-settlement-failure.sh silent
```
Kubernetes: **Succeeded**. Log: "settlement complete." Exit 0. **Nothing is red anywhere** —
except `SettlementZeroRecords`, one minute later. Without that rule you find out from
finance. → `incidents/INC-0005.md`. This is the most realistic failure in the series.

```bash
./scripts/44-settlement-failure.sh strict
```
The fix from INC-0005's follow-up, shipped: same silent fault, but the job **refuses to call
it success** — exit 2, Job Failed, log names `reason=zero_records`. Four signals agree
instead of one. The alert becomes a backstop instead of the only line of defence.

```bash
./scripts/44-settlement-failure.sh none
```

---

## Wrap

```bash
git add -A && git commit -m "Day 5: SLOs, burn-rate alerts, settlement job, INC-0004/0005" && git push
./scripts/48-checkpoint-day5.sh
```

---

## Also new today

**`./scripts/up.sh`** — the post-restart recovery you've typed by hand three times, as one
command: starts containers, re-exports the kubeconfig, clears tombstones, checks every
incident knob is at baseline and **resets any that aren't**, tests the front doors, and
tells you which terminals to start. `--check` for read-only.

**Revert-on-exit on every drill** — `14`, `24`, `35`, `41`. An interrupted script can no
longer leave an injection behind.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Recording rules missing | `release: kps` label | Prometheus → Status → Rules |
| Burn alert "never fires" | You waited 2 min | It's ~8.5 at 0.50; ~40 at 0.10. See `docs/slos.md` |
| 30d panels look wrong | Only days of data, 10d retention | Expected; numbers are still valid |
| Pushgateway metrics missing | Wrong service name in `PUSHGATEWAY` | `42-install-pushgateway.sh` checks it |
| `SettlementJobFailed` won't clear | Old Failed jobs | Fixed rule only counts last 15 min; or `kubectl delete jobs -n payments -l app=settlement` |
| CronJob never runs | Schedule/suspend | `kubectl describe cronjob settlement -n payments` |
| `kube_job_status_failed` empty | kube-state-metrics | `kube_job_info` in Prometheus to confirm it scrapes |

## What's next

Day 6 is CI/CD: a Jenkins pipeline that builds, tests and deploys, with a deliberately bad
release — the most common incident of all, "it broke right after the deploy," and the most
common fix, the rollback.
