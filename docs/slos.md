# Service Level Objectives — activation

Decided before any code was written. Deciding is the hard part; the PromQL is easy.

## Vocabulary, once

| Term | Meaning | For activation |
|---|---|---|
| **SLI** | a measurement | fraction of requests with `status="ok"` |
| **SLO** | a target for that measurement | 99.5% over 30 days |
| **Error budget** | what the SLO leaves you | 0.5% of requests may fail |
| **Burn rate** | how fast you're spending the budget vs plan | 1× = budget lasts exactly 30 days; 14.4× = gone in ~2 days |

Why this matters for incident response: it replaces *"the error rate is 4%, is that bad?"*
with *"at this rate we blow the month's budget by Thursday."* That is a sentence
leadership understands.

## The two SLOs

| SLO | SLI | Target | Window | Budget |
|---|---|---|---|---|
| **Availability** | `status="ok"` requests ÷ all requests | **99.5%** | 30 days | 0.5% of requests |
| **Latency** | requests completed under **300 ms** ÷ all requests | **99%** | 30 days | 1% of requests |

### Why 99.5% and not 99.99%

Every extra nine costs engineering effort — roughly 10× per nine. Card activation at a
till has a human waiting, so it matters, but a retry is cheap and the cashier will try
again. 99.5% is honest for this service's actual failure modes.

## A real finding: the service is over budget by design

The lab's `ERROR_RATE` default is **0.02 — a 2% error rate**. The availability budget is
0.5%. **The service burns budget at 4× the sustainable rate, permanently.** It will never
meet the SLO as configured.

Both burn-rate alerts stay quiet at 4× because their thresholds are 6× and 14.4×. That
is the deliberate gap between *"over budget"* (a planning problem, fix it in the roadmap)
and *"burning fast"* (an incident, page someone). A service can be quietly failing its SLO
for weeks without ever paging — and that is by design, and it is *why the budget-remaining
panel exists*. That panel is the one to show a manager.

## Burn-rate alerts (Google SRE Workbook, used almost verbatim across the industry)

| Alert | Burn rate | Long window | Short window | Budget consumed by the time it fires | Severity |
|---|---|---|---|---|---|
| `…BurnFast` | 14.4× | 1h | 5m | 2% of the month | critical — page |
| `…BurnSlow` | 6× | 6h | 5m | 5% of the month | warning — ticket |

How to read the expression `(1 - ratio_rate1h) > 14.4 * 0.005`: `0.005` is the allowed
error fraction; `14.4 ×` that is 7.2%. The **long** window proves it is sustained; the
**short** window proves it is *still* happening, so the alert resolves quickly after a fix.

### The arithmetic the PDF gets wrong

Starting from the 2% baseline, how long until the **1-hour** window crosses 7.2%?

| Injected `ERROR_RATE` | Time for the 1h average to cross 7.2% | + `for: 2m` |
|---|---|---|
| 0.10 | **~39 min** | ~41 min |
| 0.30 | ~11 min | ~13 min |
| 0.50 | ~6.5 min | ~8.5 min |

The PDF says "after about two minutes" at 0.10. It is off by a factor of twenty, because
the 1h window is an *average*, and averages move slowly — which is the entire reason the
long window exists. The drill uses **0.50** so you see it fire in under ten minutes; the
script prints the ETA.

After rollback, the **5m** window drops below threshold in ~4.5 minutes and the alert
resolves. That part the PDF gets right.

## Recording rules

Named `service:sli_name:ratio_rateWINDOW` — the Prometheus community convention you
will see in every mature setup. Precomputed every 30s so dashboards and alerts stay fast.

- `activation:sli_availability:ratio_rate5m` / `1h` / `6h`
- `activation:sli_latency:ratio_rate5m`

## Known limitation of this lab

kube-prometheus-stack's default retention is **10 days**. A 30-day window can never fill;
the "30d" panels are really "since Day 2, up to 10 days". The numbers are still valid —
the window just is not full. Production would set `retention: 45d` (window + margin).
