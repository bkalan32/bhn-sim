# Day 5 — Corrections Log

Source: `day5slosandsilentfailure.pdf` · Verified 2 September 2026.

The concepts in this PDF are the best in the series and the PromQL is largely right.
The errors are in the *timing claims* and in what happens after you fix things.

---

## [BUG] B1 — "After about two minutes the alert fires." It takes ~39.

**Guide, Step 5:** set `ERROR_RATE=0.10`, "watch the burn-rate panel climb to 20. After
about two minutes `ActivationErrorBudgetBurnFast` fires."

The rule requires the **1-hour** window's error rate to exceed `14.4 × 0.005 = 7.2%`.
`rate(...[1h])` is an average over the last hour. Starting from a 2% baseline and
injecting 10%:

```
(0.10·t + 0.02·(60−t)) / 60 > 0.072   →   t > 39 minutes
```

Then `for: 2m`. **~41 minutes**, not 2. The PDF is off by a factor of twenty — not because
the rule is wrong but because *long windows move slowly, and that is the entire reason
they exist.* The "20" the burn-rate panel reaches is the 5-minute burn rate; the 1-hour one
crawls.

**Substitute:** the drill injects **0.50**, which crosses in ~6.5 min. `41-burn-budget.sh`
computes and prints the ETA from the formula, then watches the alert state every 30s.
The recovery claim ("resolves within a few minutes because of the 5m short window") is
**correct** — ~4.5 min after rollback.

---

## [BUG] B2 — `SettlementJobFailed` never resolves

**Guide, Step 9:** `kube_job_status_failed{job_name=~"settlement.*"} > 0`

Kubernetes keeps the last `failedJobsHistoryLimit: 3` Job objects around indefinitely.
kube-state-metrics reports `kube_job_status_failed = 1` for each of them, forever. After
you fix the cause and reset to `none`, the alert **keeps firing** for jobs that failed an
hour ago — contradicting the PDF's "reset to none and confirm everything resolves."

**Substitute:** join on `kube_job_status_start_time` so only jobs that started in the last
15 minutes count. Alerts on *history* are a classic source of alert fatigue.

---

## [BUG] B3 — No `concurrencyPolicy` on a money-moving job

The PDF's CronJob has no `concurrencyPolicy`, so the default `Allow` applies. If a run
overlaps the next tick — a slow database, a hung push — you get two settlements at once.
In real finance that is a **double payment**. Added `concurrencyPolicy: Forbid` and an
`activeDeadlineSeconds` so a hung job cannot run forever.

---

## [BUG] B4 — One timestamp cannot distinguish three different failures

The PDF's job publishes only `settlement_last_success_timestamp`. From that one number
you cannot tell apart:

- the job never ran (scheduler problem)
- the job ran and crashed (code problem)
- the job ran, succeeded, and did nothing (the silent one)

Added `settlement_last_run_timestamp` and `settlement_last_run_status` so the dashboard
and alerts can. `SettlementStale` alone now means "did not run or did not succeed";
`Stale` + fresh `last_run` + `status=0` means "ran and failed"; `ZeroRecords` means "ran
and lied."

---

## [BUG] B5 — A push failure would hide the job's real outcome

`push_to_gateway` at the very end of the PDF's script, unguarded. If the Pushgateway is
unreachable the job **crashes on the push**, exits non-zero, and now a metrics-plumbing
problem looks like a settlement failure. Wrapped in try/except: the push failure is
logged, the job's own exit code reflects the job's own outcome.

---

## [DESIGN] D1 — The fix the PDF describes but does not ship

INC-0005's follow-up says "the job itself should refuse to report success on zero
records." Correct — and now implemented behind `SETTLEMENT_STRICT`. Off by default so you
can *watch* the silent failure happen first; `44-settlement-failure.sh strict` turns it
on and shows all four signals agreeing. The follow-up action is to make it the default.

---

## [PLATFORM] P1 — Prometheus retention is 10 days

kube-prometheus-stack defaults to `retention: 10d`. The 30-day `increase()` panels can
never fill. The PDF's note ("30d is really since Day 2") is right but incomplete — it will
*stay* incomplete. Production would set retention to window + margin (45d). Noted in
`docs/slos.md`; not changed here because it would need a Prometheus restart.

---

## [PLATFORM] P2 — `honorLabels` on the Pushgateway ServiceMonitor

Without it, Prometheus renames the pushed `job="settlement"` label to `exported_job`
because it collides with the scrape job label. The PDF's queries still work (they don't
filter on `job`), but anyone who later writes `{job="settlement"}` gets nothing and
wonders why. `--set serviceMonitor.honorLabels=true`.

---

## Verified as correct

- The SLO/SLI/error-budget/burn-rate vocabulary. The single best paragraph in the series.
- The recording-rule naming convention `service:sli_name:ratio_rateWINDOW`.
- The burn-rate thresholds (14.4× / 1h+5m / critical; 6× / 6h+5m / warning), taken
  from the Google SRE Workbook — and the explanation of why two windows.
- The observation that the lab service is over budget by design at 4×, and that neither
  alert fires. That gap between "over budget" and "burning fast" is real and intentional.
- The error-budget-remaining formula.
- **"Alert on absence, not presence."** The most transferable idea in Day 5.
- The silent-failure framing. Every payments company really does have that story.
