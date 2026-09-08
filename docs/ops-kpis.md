# Operational KPIs — the evidence that the AI layer did something measurable

Two numbers per incident from now on: **time to detect** (fault → first alert) and **time
to diagnose** (first alert → correct cause identified, by a human or the bot). Detection has
been steady since Day 3 (`for: 2m` + evaluation ≈ 2–2.5 min for the error-rate alert).
Diagnosis is what Days 9 and 10 attack — and the only way to say "the AI helped" without
hand-waving is a column that got smaller.

## How each number is measured

| Column | Definition | Source |
|---|---|---|
| TTD | first alert − fault injected | drills post `drill: fault injected at <iso>` as a note; real incidents have no fault time — leave `-` |
| TTT | ticket opened − first alert | `group_wait` + webhook; Alertmanager routing (Day 8) |
| TTX | context attached − ticket opened | the three lookups (Day 10) |
| TTH | hypothesis attached − ticket opened | enrichment + two AI calls (Day 10) |
| **TTDiag (human)** | first alert → a human wrote the correct cause on the record | the first responder note naming it; Days 3–8 from your own notes in the INC files |
| **TTDiag (bot)** | first alert → the hypothesis named the correct cause | TTT + TTH, *if* the hypothesis was right (grade in `docs/ai-eval.md`) |

`python3 tools/kpis.py` prints the mechanical columns for every record on the bot. The
two TTDiag columns are yours to fill — they require a judgement about *correctness*.

## The table

Backfilled for the nine incidents before Day 10 from the INC write-ups (times are
approximate where they came from a terminal rather than the record), then live from the
bot. Paste `tools/kpis.py` output below and add the diagnosis columns.

| # | Record | Fault | TTD | TTT | TTX | TTH | TTDiag human | TTDiag bot | Right? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 0001 | (pre-bot, Day 3) | fraud dependency | ~2 min | – | – | – | ~10 min (alert → Grafana → write the Splunk `by app.reason` search) | – | – | first time; the search had to be written |
| 0002 | (pre-bot, Day 4) | activation latency (exp. A) | human on dashboard | – | – | – | ~0 — the experiment *was* the cause | – | – | no alert existed yet |
| 0003 | (pre-bot, Day 4) | email latency (exp. B) | human on dashboard | – | – | – | ~0 — same | – | – | no alert existed yet |
| 0004 | (pre-bot, Day 5) | 50% errors | ~2 min (BurnFast) | – | – | – | n/a — cause was the drill | – | – | |
| 0005 | (pre-bot, Day 5) | silent settlement | ~1 min (ZeroRecords) | – | – | – | ~2 min (the alert name *is* the diagnosis) | – | – | Stale would have taken 15 min more |
| 0006 | (pre-bot, Day 6) | bad deploy | ~2 min | – | – | – | ~0 — the deploy annotation *was* the diagnosis | – | – | pipeline rolled back |
| 0007 | `INC-1788559916-4b4b` | fraud dependency (Day 8) | ~2 min | 16s | – | – | n/a — no responder notes; the ticket had names and times, not the cause | – | – | first ticketed incident |
| 0008 | `INC-1788806049-78f7` | fraud dependency (Day 9) | ~2 min | 29s | – | – | **4m37s** (note 1 at 18:38:46, alert 18:33:40) | – | – | human diagnosis while reading a draft |
| 0009-leak | `INC-1788825339-a7fd` | fraud dependency (Day 10, invalid) | 195s | 30s | 0s | 22s | – | (52s — not counted: the answer was in the input) | ⛔ | Eval 3-leak; logs collector "no events" (Fluent Bit → old Splunk IP) |
| 0009 | `INC-1788827585-6b7f` | fraud dependency (Day 10) | **156s** | 25s | 0s | 18s | – (none needed) | **43s** (TTT 25 + TTH 18) | **yes** | 435× fraud_service_timeout, no deploys; medium confidence, honest |
| 0010 | `INC-1788828923-e7d8` | bad deploy (Day 10, build 19) | ~156s (deploy 2.6 min before the alert) | 18s | 0s | 24s | – | 42s → **not counted** — the right cause was ranked second | half | rollback landed 0.3 min *before* the alert; hypothesis blamed the rollback |
| 0011 | `INC-1788884439-d9d2` | fraud dependency (Day 11, copilot) | ~188s | 29s | _kpis.py_ | _kpis.py_ | – | bot: TTT + TTH (right) · **copilot: 22 s from the question = 157 s from the fault, 31 s BEFORE the alert** | **yes** (both) | copilot asked at t+135 s; its Q3 invented a deploy story (Eval 4b) |

| 0014 | _Day 12 record_ | bad deploy, Verify skipped (Day 12, tier 2) | _kpis.py_ | | | | – | – | – | **alert → PROPOSED _N_ s → APPROVED _N_ s → EXECUTED _N_ s → RECOVERED _N_ s**; approve-to-recover **_N_ s** |

Cascade tickets from the same faults (egift calls activation): `INC-1788827580-2365` (with 0009) and
`INC-1788828924-519d` (with 0010) — TTT 25s/18s, TTH 22s/20s, no separate diagnosis graded.

## What to say about it

On 0009 the bot's time to diagnose was **43 seconds** from the first alert (25 s to the
ticket, 18 s to the hypothesis) and the diagnosis was right; the best human time on the same
fault was 4 m 37 s (0008) and the first time it was closer to ten minutes (0001). On 0010 the
clock reads 42 seconds but it does not count: the hypothesis named the right *event* — the
velocity-check deploy, not the fraud dependency — and put the true cause in its alternative,
but ranked the rollback first because the prompt described rollbacks as events. Same alert,
two different contexts, two different diagnoses pointing at two different, correct pieces of
evidence: that is the argument for enrichment. The honest caveat stands: the bot's diagnosis
only counts once a human confirms it, so the real metric is *time to a confirmed cause*, and
the AI moves the start of that clock — a responder now opens a ticket that already says
"probably this, here is why, medium confidence" — not the end.

Detection (TTD) has not moved and will not: 156–195 s is `for: 2m` plus a scrape and an
evaluation interval, the same since Day 3. Ticketing (TTT) is stable at 18–30 s
(`group_wait: 15s` plus the webhook). Context arrives in the same second the ticket opens
(TTX 0 s — all three collectors answered in under a second). The hypothesis lands 18–24 s
later, of which ~14 s is two AI round-trips (open draft, then hypothesis).

## Approve-to-recover (Day 12) next to the pipeline

| Path | What recovers production | alert → recovered | who decides |
|---|---|---|---|
| Day 6/10 pipeline Verify | 120 s wait + ~30 s `rollout undo`, **before any alert** — but only for releases that went through the pipeline | n/a (recovers before detection); deploy → recovered ≈ 2.5 min | nobody |
| Day 12 tier 2 | alert → PROPOSED (seconds) → a human runs `rem.py approve` → `rollout undo` (~30 s) → windows clear (2–5 min) | _fill in from 123-drill-tier2.sh_ | one human, one command |
| Manual (Day 6 shape) | a human reads the dashboard, finds the deploy, types `rollout undo` | not recorded on Day 6 | one human, three steps |

_Fill in after the drill, two sentences: the tier-2 number, and the honest caveat — the
pipeline path is faster for deploys because it does not wait for an alert; the tier-2 path
covers what the pipeline cannot (a release that slipped Verify, a config change, a rollback
needed later) and turns "find the cause, decide, type" into "decide"._

Cost line for the day: 6 tickets (2 drills × activation + egift, plus the invalid first run)
× 3 AI calls = 18 calls, **42,869 tokens**, 190 s of model time. At Sonnet list prices
(mostly input tokens, ~3–4k per record) that is roughly **$0.20 for the day** — less than
the coffee consumed waiting for alert windows. The valid drills alone: 29,154 tokens.
