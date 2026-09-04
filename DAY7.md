# Day 7 — The Health Score, the Overview, and the First Real Fix

Adapted from `day7healthscoreandfirstfix.pdf`. Changes in **[CORRECTIONS-DAY7.md](CORRECTIONS-DAY7.md)**.

> The PDF's health-score formula doesn't move — at 10% errors it reads 94, green. And its
> platform average returns nothing because the settlement metrics carry labels the others
> don't. Both fixed; the arithmetic is in `docs/health-score.md`.

---

## Why a consolidation day

Six days of building. Real teams do this too: after a heavy incident period, stop, look at
what the incidents have in common, and spend engineering time on causes instead of
symptoms. Four jobs today, and the fourth is the one that matters.

---

## Part A — The overview

**Step 1.** Import `dashboards/overview.json`. One row per workload, a platform row on top,
colour thresholds everywhere. During triage the first minutes are: one service or all? Us or
a dependency? Just now or hours? This screen answers *"where do I look next?"* in ten
seconds. The deploy list sits next to the alert count **on purpose** — "it broke right after
a deploy" is the most common diagnosis in the business.

Two panels will read "No data" until Part B loads the scores. That's expected.

---

## Part B — The health score

**Step 2.** Read `docs/health-score.md` **first** — the opinion, written before the PromQL.
What 100 means, what drops it, how fast. Weights are choices and defending them is the
job.

**Step 3.** Load and read:

```bash
./scripts/60-health-scores.sh
```

Activation should read **~82 — yellow.** Not a bug: its 2% baseline is 4× over budget, and
a score that reads green for an over-budget service is lying.

**Step 4.** Prove it moves — a score that stays green while things break is worse than none:

```bash
./scripts/61-score-sanity.sh
```

Injects 10% errors. With the PDF's formula, activation would read 94. With this one it falls
to ~40 within three minutes and the platform to ~75. Then it recovers.

Note what the score does *not* tell you: which thing broke. Scores spot and rank.
Dashboards diagnose.

---

## Part C — The week-one review

**Step 5.** Open `docs/week1-review.md` and fill in your real diagnosis times from
INC-0001 to 0006. Then read the three questions and their answers.

The one that matters: **the recurring theme is the fraud dependency, and the multiplier
was the 3-second timeout.** One dependency failed; activation held every connection open
for 3s; thread pools filled; eGift stacked waits on top. The failure was small. The blast
radius was the timeout.

The backlog at the bottom is ranked. Item 1 is today. Items 4–6 are already done — the
review says so.

---

## Part D — The first permanent fix, through your own pipeline

**Step 6.** Read the change in `services/activation/app.py` — search for
`FRAUD_CLIENT_TIMEOUT_S`. Two constants: how long the *dependency* hangs (not ours), how
long *we* wait (ours). Cap it at 300ms. Requests still fail — correctly — but cheaply.

Also this build enforces the production-amount test in the pipeline (backlog #4). The
velocity-check release would now die at *Test*.

**Step 7.** Ship it the way you'd ship anything now:

```bash
git add -A && git commit -m "activation v0.4: fail fast on fraud dependency (INC-0001)"
```

Jenkins → **Build with Parameters** → `CHANGE_CAUSE=fail fast on fraud dependency (INC-0001 follow-up)`.
Green. Blue line on every dashboard. "Running versions" now shows the build number.

**Step 8.** Re-run the original incident, with numbers:

```bash
./scripts/62-fail-fast-drill.sh
```

Same `FRAUD_SVC_DOWN=true` as Day 3. Error rate still 100% (correct). But **p95 ~0.3s
instead of ~3s, and eGift barely moves.** Same outage, a fraction of the blast radius.

**Step 9.** Add a *"fix verified"* line with before/after numbers to `incidents/INC-0001.md`
and the table at the bottom of the review.

That loop — incident, follow-up, engineered fix, re-test, evidence — is the exact sentence in
your job description: *"engineer permanent solutions rather than repeatedly fixing the same
thing."* You've now done it once, for real, through a pipeline you built.

---

## Wrap

```bash
git add -A && git commit -m "Day 7: overview, health scores, week-1 review, fail-fast verified"
./scripts/68-checkpoint-day7.sh
```

---

## What's next

Week 2 turns toward automation and AI. Day 8 wires Alertmanager into an incident bot you
build yourself: alerts become incident records with timelines, automatically — the foundation
the AI work sits on.
