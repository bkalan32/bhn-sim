# Day 7 — Corrections Log

Source: `day7healthscoreandfirstfix.pdf` · Verified 2 September 2026.

---

## [BUG] B1 — The health score does not move. At 10% errors it reads 94.

**Guide, Step 2:** `60 * clamp_max(activation:sli_availability:ratio_rate5m / 0.995, 1)`
**Guide, Step 3:** "Break something mildly: `ERROR_RATE=0.10`. Watch the activation score
drop into the 50s and the platform score into the 80s."

Arithmetic: 10% errors → availability 0.90 → `0.90 / 0.995 = 0.905` → **54.3 points** of 60,
plus 40 latency points untouched → **94**. Platform: `(94 + 100 + 100) / 3 = 98`. Not the 50s
and 80s; green and green.

| errors | PDF score | this score |
|---|---|---|
| 2% (baseline) | 99 | 82 |
| 10% (the drill) | **94** | **40** |
| 50% | 70 | 40 |

Normalising against the SLO target compresses everything between "perfect" and
"disaster" into a few points, because the target is so close to 100%. **Substitute:**
anchor zero at ten error budgets below target (`(avail − 0.95) / 0.045`), so the score
spans the range that matters. Full derivation in `docs/health-score.md`.

The PDF's own troubleshooting note — *"score stuck at 100 while things are broken: a
term is mis-normalised"* — describes its own formula.

---

## [BUG] B2 — The platform average returns nothing

`(activation:health_score + egift:health_score + settlement:health_score) / 3`

PromQL binary operators match on labels. The activation and egift scores come from
`sum()` aggregations and carry **no labels**. The settlement score comes from Pushgateway
metrics and carries `job="settlement", instance=""`. Mismatched label sets → no matching
series → **the platform score is silently empty.** The overview's headline panel reads
"No data." Fixed with `max()` around the settlement terms, which strips the labels.

---

## [BUG] B3 — The first activation rule as printed is not valid PromQL

The PDF's initial `activation:health_score` contains `+ 20 * clamp_max((… < bool 900) + 0,
1) * 0 + 20` — unbalanced parentheses and a term multiplied by zero. It then says "simplify
if it looks odd; the honest version is…" and gives a second rule. Only the second one is
used here, with B1's normalisation fix.

---

## [BUG] B4 — The fail-fast snippet reintroduces Day 2's bugs (again)

Unlabelled `LATENCY.observe`, `time.time()` against a `perf_counter()` start. Fourth
time. Applied against this codebase instead, as a **separate client-side constant**:
`FRAUD_TIMEOUT_S` is how long the dependency hangs (not ours to control),
`FRAUD_CLIENT_TIMEOUT_S` is how long *we* wait (ours). That's the honest model of "client
timeout + circuit breaker." Measured locally before shipping: **3.08s → 0.42s** to the same
503.

---

## [BUG] B5 — `APP_VERSION` env in the manifest hides the pipeline's build number

Every pipeline image bakes its build number into `APP_VERSION` via the Dockerfile, but the
manifest's `env` set it to `"0.3"`, and env wins. The "Running versions" panel read 0.3
through builds 3, 4, 5, 6… Removed from the manifest; the image's value now shows, so the
panel answers "what version is running" with the build number, which was the point.

---

## [DESIGN] D1 — Step 5 is already done

"The Verify stage hardcodes `_requests_total`; add a `METRIC_PREFIX` parameter." Day 6's
Jenkinsfile maps the metric per service. Skipped. Backlog items 4, 5 and 6 in the review
are likewise already shipped; the review table says so rather than pretending otherwise.

---

## Verified as correct

- The rationale for consolidation days, the overview-first triage argument, and "deploys
  next to alerts on purpose." All right.
- Weights as choices, `clamp_max(x, 1)` so one term can't hide another, the platform score
  as a plain average that a real company would weight by revenue. Right, and worth
  saying in interviews.
- The three review questions. Right, and the second one (the fraud path as the recurring
  theme, with the 3-second timeout as the multiplier) is the real insight of the week.
- "Requests still fail, and that is correct." The fix is failing cheaply, not pretending the
  fraud check is optional. Exactly.
- `count(ALERTS{alertstate="firing", severity="critical"}) or vector(0)` — correct, including
  the `or vector(0)` so an empty result reads as zero rather than "No data."
