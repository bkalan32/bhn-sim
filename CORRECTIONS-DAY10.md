# Day 10 — Corrections Log

Source: `day10contextenrichedalerts.pdf` · Verified 7 September 2026 against the running lab.

---

## [BUG] B1 — Three network calls inside the webhook handler (the Day 9 bug, three times over)

**Guide, Step 1:** `inc["context"] = enrich.enrich(...)` "at incident creation, before the
AI call" — i.e. inside `async def receive`. Prometheus (10s timeout) + Grafana (10s) +
Splunk (20s) + the AI call = up to 100 seconds of blocking I/O in an async handler.
Alertmanager retries; health probes fail; the pod restarts while it is diagnosing. Same
class as CORRECTIONS-DAY9 B1, with a longer fuse. Enrichment runs in the Day 9 background
thread, *before* the open draft, so the summary and the hypothesis both see the context.

---

## [BUG] B2 — Credentials in source: a container IP and `admin:password` in base64

**Guide, Step 1:** `SPLUNK = "https://<splunk-container-ip>:8089"`,
`SPLUNK_AUTH = ("admin", "Changeme123!")`, and for Grafana
`"Authorization": "Basic <base64 admin:password>"` — all in `enrich.py`, committed.

Three problems. The Splunk container's IP changes on every restart (Day 3 learned this;
`22-fluent-bit.sh` renders it for exactly that reason), so the code breaks the first time
Docker restarts. The Grafana admin password in code means rotating it breaks the bot.
And all of it is in git. **Substitute:** `secret/enrich-config` built by
`100-enrich-config.sh` — a Grafana **service account** (Viewer) with a token minted through
the API (the PDF's own troubleshooting suggests this; we start there), the Splunk address
rendered from `docker inspect`, and `up.sh` warning when the IP drifts. `enrich.py` reads
env only.

---

## [BUG] B3 — The error-rate query divides by zero when traffic stops

`100 * sum(rate(...{status="error"}[5m])) / sum(rate(...[5m]))` — the Day 3 mistake
again. No traffic → 0/0 → NaN → the PDF's `float(...)` returns `nan`, which JSON-serialises
as `NaN` and which no model reads sensibly. `clamp_min(..., 0.001)` in the denominator,
and NaN → `null` on the way out.

---

## [BUG] B4 — `tags=deploy` returns every service's deploys, and no ages

**Guide, Step 1:** `GET /api/annotations?...&tags=deploy` → "the last 5". During an
activation incident that list is polluted by egift and settlement deploys, and rollbacks
(tagged `rollback`, not `deploy`) — the single most diagnostic event — are excluded. The
PDF's troubleshooting then admits: *"Hypothesis blames a deploy that is 6 hours old …
consider passing the incident open time explicitly."* Done at the source: the lookup is
filtered to **this service's** tag, includes rollbacks, and every entry carries
`minutes_before_first_alert` (negative = after the alert). The prompt says what to do
with that number: 0–30 weighs heavily; hours old or negative is not a cause.

---

## [BUG] B5 — Drill B cannot run as written

**Guide, Step 3:** "re-apply the velocity-check bug on a branch, but first remove the
amount-mix test you added on Day 8 (temporarily)". Two things. The pipeline builds
**main**, not a branch (Day 6 job config, `*/main`) — a branch never deploys. And
"remove the test" by hand is how temporary changes become permanent. `ci/amount_test_gate.py
disable|enable` puts a **skip marker that names the drill** on the test; `103-drill-b.sh
apply` commits both changes with `DO NOT KEEP` in the message and `revert` undoes both. The
Day 10 checkpoint refuses to pass while the marker is present.

---

## [BUG] B6 — The Splunk search window is longer than the incident

`earliest=-10m` at ticket-open time (≈2.5 min after the fault) includes ~7 minutes of the
baseline 2% errors (`simulated_failure` or similar). For Drill A that still ranks
`fraud_service_timeout` first by a wide margin; for a subtler fault it would not. Kept at
10 minutes for the lab (it is what the PDF verifies against), noted here: in production,
window the search from the first alert's `startsAt` minus one `for:` interval.

---

## [DESIGN] D1 — Enrichment runs without the AI, and the hypothesis says when a collector failed

Context is useful to a *human* even when no model is configured, so `_schedule_draft`
still enriches when `AI_PROVIDER=none`. Each collector reports `ok`/`error` into
`context_meta` and a metric (`enrich_collector_total{collector,outcome}`), and the
hypothesis prompt is told to name a failed collector and lower its confidence. The PDF's
exit criterion — "every collector degrades gracefully (test by stopping Splunk)" — is
therefore observable on the record and on a panel, not only in the absence of a crash.

---

## [DESIGN] D2 — Eval 3 measures two things and keeps them apart

The Day 9 prompt fixes (four rules from Evals 0–2) ship in this build. Eval 3 in
`docs/ai-eval.md` grades the *drafts* for those four defects and grades the *hypotheses*
for correctness separately, so "the prompt got better" and "enrichment made the diagnosis
right" are two findings, not one.

---

## [NOTE] N1 — Day 9 checkpoint: evidence on disk

`93-ai-resilience.sh` now writes `checkpoints/day9-resilience.txt`; `98-checkpoint-day9.sh`
reads it. The original check read a counter in the bot, and restoring the provider restarts
the bot, which zeroes the counter. Evidence that must survive a restart goes on disk.

## [NOTE] N2 — Numbering

Drill A = INC-0009, Drill B = INC-0010 (the PDF says 0008/0009; ours are one higher since
Day 8's drill was written up as INC-0007).

---

## Verified as correct

- The three pillars as the three lookups a human does first, and "what changed?" as the
  highest-value one. Right.
- "Every collector catches its own exceptions and returns an explanatory stub. Enrichment
  that takes down intake is worse than no enrichment; this rule is absolute." The best
  sentence in the PDF; the tests enforce it (`test_enrich.py`).
- Port 8089 with the admin login, not 8088 with the HEC token — "a classic confusion worth
  learning now." Right; `100-enrich-config.sh` proves the login before storing it.
- "Diagnosis only" as the safety boundary, and structured output with a confidence field.
  Right; the prompt adds "a rollback after the alert is not a cause" because the enriched
  context now contains rollbacks.
- Time-to-detect and time-to-diagnose as the two KPIs, and backfilling them. Right;
  `docs/ops-kpis.md` splits diagnosis into *human* and *bot* columns because the bot's
  diagnosis only counts once a human confirms it.
