# Week 1 incident review

Read like an outsider. Six incidents, one table, three questions, one ranked backlog.

## The table

| # | Detected by | Time to diagnose | Root-cause category | Permanent fix |
|---|---|---|---|---|
| 0001 | `ActivationHighErrorRate` alert | _fill in_ (alert → Splunk `by app.reason`) | dependency failure (fraud) | **Shipped Day 7** — fail fast, 3s → 0.3s |
| 0002 | dashboard (human) | _fill in_ | dependency latency (activation) | n/a — drill. Gap: no alert on egift step latency |
| 0003 | dashboard (human) | _fill in_ | own-step latency (email) | n/a — drill. Gap: no alert fired at all |
| 0004 | `ActivationErrorBudgetBurnFast` | _fill in_ | elevated errors | n/a — drill. Finding: 2% baseline is 4× over budget |
| 0005 | `SettlementZeroRecords` — and *only* that | _fill in_ | silent batch failure | **Shipped Day 8** — `SETTLEMENT_STRICT=true` default, `settlement:0.2` |
| 0006 | pipeline Verify | ~2 min (automated) | bad deploy | **Shipped Day 8** — auto-rollback + amount-mix test always on |

## The three questions a good team asks

**Which detections came from a human looking at a screen?**
0002 and 0003. Screens do not watch themselves at 3 AM. Both were latency problems on
eGift, and there is no eGift latency alert — `ActivationHighLatency` exists, `EgiftHighLatency`
does not. That is a gap, not a drill artefact.

**What is the recurring theme?**
Two of six (0001, and 0002's dependency half) involve the **fraud / activation dependency
path being slow or down** — and in 0001 activation held every connection open for the full
3-second timeout, which multiplied the damage: thread pools filled, eGift orders stacked
multi-second waits, and the p95 went past 3s. The failure was one dependency; the *blast
radius* was the timeout.

**What is the cheapest fix with the biggest effect?**
Fail fast on the fraud dependency. One constant, one line of code, shipped through the
pipeline in a single build. Requests still fail — correctly — but in 300ms instead of 3s,
threads stay free, and eGift barely notices. Measured locally before shipping: **3.08s → 0.42s**.

## Ranked backlog

| # | Item | From | When | Status |
|---|---|---|---|---|
| 1 | Fail fast on fraud dependency (`FRAUD_CLIENT_TIMEOUT_S=0.3`) | INC-0001 | Day 7 | **done** — v0.4 via pipeline |
| 2 | `SETTLEMENT_STRICT=true` as the default, not an opt-in | INC-0005 | Day 8 | **done** — `settlement:0.2` via pipeline |
| 3 | `EgiftHighLatency` alert + per-step alert naming the culprit | INC-0002/3 | Day 8 | **done** — `EgiftHighLatency`, `EgiftStepSlow`, `EgiftHighErrorRate` |
| 4 | Production-amount test enforced in the pipeline | INC-0006 | Day 7/8 | **done** — ungated on Day 8; proven with `84-test-catches-bug.sh` |
| 5 | Verify compares to pre-deploy baseline | INC-0006 | Day 6 | **done** |
| 6 | Verify is per-service aware (`egift_orders_total`) | INC-0006 | Day 6 | **done** |
| 7 | Should business declines (`issuer_declined`, `velocity_check_blocked`) count against the *availability* SLI at all? | INC-0004/6 | Day 9 | open — SLI-definition question, needs product |
| 8 | Canary: one replica first, verify, then the rest | INC-0006 | Day 12 | open |

## Before / after — INC-0001 re-run with the fix (fill in from `62-fail-fast-drill.sh`)

| | Day 3 (3s hang) | Day 7 (0.3s cap) |
|---|---|---|
| activation error rate | 100% | _fill in_ (still ~100% — correct) |
| activation p95 | ~3.0s | _fill in_ (~0.3s) |
| eGift p95 order latency | _fill in_ | _fill in_ |
| eGift order rate during outage | _fill in_ | _fill in_ |

Same outage. A fraction of the blast radius. That loop — incident, follow-up, engineered fix,
re-test, evidence — is what "engineer permanent solutions rather than repeatedly fixing the
same thing" means in practice.
