# Health score — the opinion, written down first

A health score compresses SLIs into one 0–100 number per service. It is listed in the job
description because someone has to *own the definition*, and the definition is where all
the judgment lives. This is that definition.

## What 100 means, what drops it, how fast

| Service | Term | Weight | 100% of points at | 0% of points at |
|---|---|---|---|---|
| **activation** | availability (5m) | 60 | ≥ 99.5% (the SLO) | ≤ 95% (ten budgets below) |
| | latency ≤ 300ms (5m) | 40 | ≥ 99% (the SLO) | ≤ 90% |
| **egift** | order success (5m) | 70 | ≥ 99.5% | ≤ 95% |
| | p95 order latency (5m) | 30 | ≤ 0.5s | ≥ 2.5s |
| **settlement** | last success within 15 min | 70 | yes | no |
| | last run processed > 0 records | 30 | yes | no |
| **platform** | plain average of the three | | | |

Every term is linear between its two anchors and clamped at both ends
(`clamp_max(x, 1)` so overachieving on one term cannot hide failure on another).

## Why "ten budgets below", not "the target" — the PDF's formula does not move

The PDF normalises against the SLO target: `60 × (availability ÷ 0.995)`. It then claims
that 10% errors drops the score "into the 50s." Arithmetic:

| errors | availability | PDF score | this score |
|---|---|---|---|
| 0.5% (on budget) | 99.5% | 100 | 100 |
| **2% (lab baseline)** | 98.0% | 99 | **82** |
| 5% | 95.0% | 97 | 46 |
| **10% (the PDF's drill)** | 90.0% | **94** | **40** |
| 50% | 50.0% | 70 | 40 |

Ten percent of customers failing at the till, and the PDF's score reads **94 — green.** A
50% outage reads 70. The reason: the target is so close to 100% that everything between
"perfect" and "disaster" is squeezed into a few points. **A score that stays green while
things are broken is worse than no score.**

Anchoring the zero at ten error budgets below target spreads the useful range out. The lab's
everyday 2% baseline scores **82 — honestly yellow**, because it is over budget. That is a
real finding, not a bug.

## Weights are choices, and defending them is the job

- Activation: availability 60 / latency 40 — a failed activation is worse than a slow one.
- eGift: success 70 / latency 30 — a corporate order can wait a second; it cannot fail.
- Settlement: freshness 70 / non-zero 30 — stale settlement is the disaster case.
- Platform: a plain average. In a real company this would be weighted by revenue per
  flow, and arguing those weights with product owners is genuinely part of the role.

## Thresholds on the overview

| Score | Colour | Meaning |
|---|---|---|
| ≥ 90 | green | meeting SLOs |
| 70–89 | yellow | over budget, not paging — a roadmap conversation |
| < 70 | red | incident territory |

## What the score does NOT tell you
Which thing broke. Scores are for spotting and ranking. Dashboards are for diagnosing.
