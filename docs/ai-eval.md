# AI draft evaluation log

Every AI draft the bot produces is graded here against the record it was written from.
Two reasons: evaluating AI output is a discipline the role expects, and this file is the
before/after evidence when the prompts or the record improve.

**How to grade.** Open `incidents/INC-0008-ai-drafts.md` (the timeline is the ground
truth). For each draft, list every *claim* — a time, a number, an alert name, a cause, a
customer impact — and mark it. Then the summary line.

| Mark | Meaning |
|---|---|
| ✅ supported | the record contains it |
| ⚠️ inferred | reasonable from the record, but not stated in it (e.g. "cards declined at tills" from the system prompt's business context) |
| ❌ invented | not in the record and not derivable — a hallucination, even if it happens to be true |
| ⛔ missed | in the record, should have been in the draft, is not |
| 🆗 not yet known | the model correctly declined to fill a heading |

A draft is **usable** if it has zero ❌ and a human could send it after light edits.
A draft with one ❌ is **unusable**, however fluent — one invented number in a stakeholder
update costs more trust than ten empty headings.

---

## Eval 0 — smoke test (`91-ai-smoke.sh`, 2026-09-07)

Record: `INC-1788805056-155e` (synthetic, service `smoke-test`, one alert `SmokeTest`, one-line
summary, no runbook, no description; deleted after the run) · Model: `claude-sonnet-4-5`
· open 5,614 ms, 662→145 tokens · resolved 5,934 ms, 1,115→289 tokens · < $0.01 for both

### ai_open_draft

| Claim | Mark | Note |
|---|---|---|
| "SmokeTest alert is firing for the smoke-test service as of 2026-09-07T18:17:36Z" | ✅ | alert name, service and `starts_at_iso` all on the record |
| "synthetic alert generated from tools/inc.py" | ✅ | the alert's `summary` annotation |
| "does not affect any customer flow" | ⚠️ | reasonable from *synthetic*; the record states no impact either way |
| "No runbook is available for this alert" | ✅ | `runbook: null` |
| "standard smoke-test validation procedures should be followed" | ❌ | no such procedure exists anywhere on the record — filler with the shape of a runbook |
| stakeholder: "does not impact customer transactions or platform functionality" | ⚠️ | same inference as above |
| stakeholder: "the engineering team is validating that all monitoring and alerting systems are operating correctly" | ❌ | **an activity nobody is performing.** The prompt asks "what the team is doing"; with nothing on the record the model invented a plausible answer instead of saying so |
| "We will provide an update within 30 minutes" | ✅ | instructed |

Usable? **no** · Invented: 2 · Missed: 0

### ai_resolution_draft

| Heading | Filled or 'not yet known'? | Correct call? |
|---|---|---|
| Resolution note: "0.1 minutes (approximately 6 seconds) from 18:17:36Z to 18:17:44Z" | filled | ❌ **36→44 is 8 seconds.** It back-computed from the rounded `duration_min` (0.1 min = 6 s) and presented it as reconciled with the timestamps. A number, derived from real data, wrong, confident. |
| Close-out: "triggered and cleared automatically" | filled | ⚠️ it cleared because a resolved webhook arrived; "automatically" is an inference |
| Impact | "Not yet known (smoke-test service, warning severity)" | 🆗 |
| Timeline | filled from the record, including the `ai_draft_attached` event | ✅ faithful (and honest, if odd, to list its own draft) |
| Detection | "Alert-based detection via SmokeTest alert at 18:17:36Z" | ✅ |
| Root cause | not yet known | 🆗 correct — nothing on the record |
| What went well | not yet known | 🆗 |
| Follow-up actions | not yet known | 🆗 |

Usable? **no** (one ❌) — but *nearly*: strike one sentence and it ships. · Invented: 1 · Missed: 0

**What Eval 0 says about the prompt.** The system prompt forbids inventing "metrics,
causes, or times". Both failures slipped between those words: an invented *activity*
("the team is validating…") and an invented *derived number* (the 6-second arithmetic).
Prompt change queued for the Day 10 build: (1) *do not describe any action by the team
unless a timeline note says it happened; if the record has no notes, say "no responder
actions recorded yet"*; (2) *quote `duration_min` as given; do not compute durations from
timestamps*. Eval 3 (Day 10) measures whether that worked.

---

## Eval 1 — no notes on the record (Day 8 drill, drafted after the fact, 2026-09-07)

Record: `INC-1788559916-4b4b` (activation, critical, one alert `ActivationHighErrorRate` with
rendered description + runbook; opened 22:11:56Z, resolved 22:15:56Z, 4.0 min; **no notes**)
· drafted with `tools/inc.py draft … open` / `resolved` three days after the fact
· Model: `claude-sonnet-4-5`

### ai_open_draft

| Claim | Mark | Note |
|---|---|---|
| "**IMPORTANT: This incident is already RESOLVED as of 2026-09-04T22:15:56Z** … closed approximately 3 days ago. Below is what would have been communicated at open" | ✅ | The current-time injection (CORRECTIONS-DAY9 B5) working: the model noticed the record contradicts the prompt's premise and said so instead of pretending. This is the behaviour you want. |
| "ActivationHighErrorRate is firing for the activation service, affecting the card activation customer flow" | ✅ | alert, service on the record; flow from the alert's description ("cards are being declined at the till") |
| "First alert fired at 2026-09-04T22:11:40Z" | ✅ | `first_alert_at_iso` |
| "error rate at 100.0%" | ✅ | the alert's rendered `description`: "Error rate is 100.0% over the last 2 minutes" |
| "cards are being declined at the till" | ✅ | same description |
| runbook: Grafana 'Activation Service' first, then the Splunk `stats count by app.reason` search | ✅ | quoted verbatim from the `runbook` annotation — exactly what "what to check first" should be |
| stakeholder: "Customers are currently unable to activate payment cards … declined at retail checkout" | ✅ | 100% error rate + the description's impact line |
| stakeholder: "Our engineering team is actively investigating the activation service and working to restore normal operations" | ❌ | **Same failure as Eval 0.** No note on the record says anyone did anything. Second occurrence → the prompt fix is confirmed necessary, not a one-off. |
| "next update within 30 minutes" | ✅ | instructed |

Usable? **no** (one ❌, the same one) — otherwise this is a good bridge summary: every number and time traceable.
· Invented: 1 · Missed: 0

### ai_resolution_draft

| Heading | Filled or 'not yet known'? | Correct call? |
|---|---|---|
| Resolution note: "4.0 minutes from 22:11:56Z to 22:15:56Z … reached 100.0%" | filled | ✅ quoted `duration_min` and the two timestamps; no arithmetic this time (56→56 gave it nothing to get wrong) |
| Close-out: "brief outage on September 4th … approximately 4 minutes … cards can now be activated normally" | filled | ✅ plain language, nothing invented |
| Impact — "Peaked at 100.0%, **declined to 25.9%** before resolution" | filled | ✅ *verify it yourself:* `tools/inc.py show INC-1788559916-4b4b` → the `alerts_resolved` event's alert `description` carries the last rendered value. The Day 8 drill terminal read `err=26%` at +31 s — consistent. A number from the record, correctly attributed. |
| Timeline — 22:11:40 first alert · 22:11:56 opened · **22:14:40 "Alert ended"** · 22:15:56 resolved | filled | ✅ all four on the record; "alert ended" is `ends_at_iso` from Alertmanager — it separated *alert cleared* from *ticket closed*, which most humans conflate |
| Detection — "16 seconds before incident was opened" | filled | ✅ correct arithmetic (40→56) |
| Root cause | not yet known | 🆗 correct — and this is the whole point of Eval 2 |
| What went well — "Automated detection triggered **within seconds of the issue beginning**" | filled | ❌ **The record does not contain when the issue began.** The fault was injected ~2 min before the first alert (`for: 2m`); "within seconds" is invented and flattering. |
| What went well — "Short incident duration (4 minutes)" / "Service recovered quickly" | filled | ✅ / ⚠️ |
| Follow-up actions | not yet known | 🆗 |

Usable? **no** (one ❌) — strike one bullet and it is a solid skeleton. · Invented: 1 · Missed: 0

**What Eval 1 adds.** With a real alert (rendered description, runbook, `ends_at`) the model
had material and used it well: nine ✅ claims, correct 16-second arithmetic, the alert-cleared
vs ticket-closed distinction, and a *not yet known* Root cause. The two ❌ are both the same
species as Eval 0 — **the model narrates things people did, or when things began, that the
record never says.** Nothing it invented was a *metric*. The system prompt's "never invent
metrics, causes, or times" was obeyed to the letter and missed the point. Prompt fix stands;
add: *"What went well" may only cite facts on the record.*

---

## Eval 2 — with responder notes (Day 9 drill, INC-0008, 2026-09-07)

Record: `INC-1788806049-78f7` (activation, critical; `ActivationHighErrorRate` then
`ActivationErrorBudgetBurnFast`; opened 18:34:09Z, resolved 18:44:31Z, 10.4 min; **two
responder notes** at 18:38:46Z and 18:43:18Z) · drafted live at open and at resolve
· Model: `claude-sonnet-4-5`

### ai_open_draft

| Claim | Mark | Note |
|---|---|---|
| "ActivationHighErrorRate is firing for the activation service, affecting the card activation customer flow" | ✅ | |
| "first fired at 2026-09-07T18:33:40Z (approximately 29 seconds before incident creation)" | ✅ | 18:33:40 → 18:34:09 = 29 s. Correct arithmetic, and it volunteered the group_wait lag unprompted |
| "Current error rate is 100.0% over the last 2 minutes … cards are being declined at retail tills" | ✅ | rendered description |
| runbook: Grafana first, then the Splunk `stats count by app.reason` query | ✅ | verbatim |
| stakeholder: "Customers attempting to activate payment cards are currently experiencing failures … declined at point of sale" | ✅ | |
| stakeholder: "The engineering team is actively investigating the root cause and working to restore service" | ❌ | **Third occurrence.** At open there were no notes; nobody had done anything yet. Same sentence, three records in a row — this is a *prompt* defect, not noise. |
| "next update within 30 minutes" | ✅ | |

Usable? **no** (the one ❌, again) · Invented: 1 · Missed: 0

### ai_resolution_draft

| Heading | Filled or 'not yet known'? | Correct call? |
|---|---|---|
| Resolution note: "10.4 minutes (18:34:09Z to 18:44:31Z) … 100%" | filled | ✅ `duration_min` quoted; 09→31 is 10 min 22 s = 10.4 |
| Resolution note: "The issue **was caused by** fraud service timeouts and has been resolved by restoring the fraud service configuration" | filled | ⚠️ **The note said "Suspect fraud dependency."** The model upgraded *suspect* to *was caused by*. Every fact is on the record; the *confidence* is not. The one edit a human must make before sending. |
| Close-out: "10-minute outage … Our team identified a fraud service configuration issue and restored normal service" | filled | ✅ note 2 ("Restored fraud service config") supports "identified … and restored" |
| Impact — duration, service, 100% | filled | ✅ |
| Impact — "burn rate reached 21x normal (14.4x the 0.5% budget), exhausting monthly budget at a pace of ~2 days" | filled | ⚠️ 21x and "~2 days" are from the BurnFast alert's summary ✅; "(14.4x the 0.5% budget)" garbles the alert's *threshold* into a second measurement. Real numbers, wrong relationship. |
| Timeline — 8 entries: first alert, opened, **note 1**, HighErrorRate resolved (27%), BurnFast fired, **note 2**, BurnFast resolved, resolved | filled | ✅ every entry on the record, in order, with the notes quoted verbatim and timestamped. Compare Eval 1's four entries. |
| Detection — "29 seconds after first alert" | filled | ✅ |
| Root cause — "Fraud service configuration issue causing timeouts on 100% of activation requests **(per responder observation in Splunk)**" | filled | ✅ **filled AND attributed.** This is the heading that was *not yet known* in Eval 1. The human observed; the AI compiled and cited. |
| What went well — "Fast detection (automated alerting)" | filled | ⚠️ vague but no longer "within seconds" — nothing false |
| What went well — "Quick diagnosis via Splunk logs identifying fraud_service_timeout" | filled | ✅ note 1, 4.5 min after open |
| What went well — "Rapid mitigation (10.4 minutes total)" | filled | ⚠️ editorial; 10.4 min is 2.5× Day 8's duration (the human was typing notes) |
| Follow-up actions | not yet known | 🆗 |

Usable? **yes** — zero ❌, two ⚠️ to soften ("suspected", fix the 14.4x clause). First usable draft of the day.
· Invented: 0 · Missed: 0

---

## The comparison (the point of the day)

Same fault, same prompts, same model. The only variable is what a human put on the record
during the incident.

| | Eval 1 (no notes) | Eval 2 (with notes) |
|---|---|---|
| Root cause | *not yet known* — correct, and useless | fraud dependency timeouts, **cited to the responder's Splunk observation** |
| Timeline detail | 4 entries (alert, open, alert end, close) | 8 entries, including both notes verbatim with timestamps |
| Invented claims | 2 (activity at open; "within seconds" at close) | 1 (the same activity sentence at open); **0 at close** |
| Would you send the stakeholder close-out as-is? | yes, but it says nothing about cause | yes, after changing "identified" to "suspects" — it now *explains* the outage |
| Resolution draft usable? | no | **yes** |

**One sentence:** two short notes typed by a human during the incident did more for draft
quality than any prompt change could — the prompt fix is needed for one narrow, repeating
defect (narrating actions nobody took); everything else that improved, improved because
the *record* got better. Effort goes to the scribe, not the prompt.

**One thing the notes also introduced:** the model turned "suspect" into "was caused by".
Better records give the model more to be confident about, including things the human was
careful *not* to be confident about. The review step exists for exactly this.

**Timing observation (for the KPI table on Day 10):** this incident lasted 10.4 min versus
4.0 on Day 8 for the same fault, because the responder paused to read a draft and type two
notes before recovering. The scribe role has a cost; a 30-second note is cheap, a
two-minute one during a 100% outage is not. Also: `ActivationErrorBudgetBurnFast` fired
at 18:41:34 — *after* recovery — because its 1-hour window kept climbing for two minutes
after the errors stopped. Correct behaviour, surprising the first time.

---

## Failures worth keeping

Any draft with a ❌ goes here with the prompt version that produced it. A documented
hallucination with its cause is what "evaluating AI systems" looks like in practice.

| Date | Record | What was invented | Prompt/system change made in response |
|---|---|---|---|
| 2026-09-07 | `INC-1788805056-155e` (smoke) | "standard smoke-test validation procedures should be followed" — a procedure that does not exist | queued for Day 10: no actions/procedures unless a note records them |
| 2026-09-07 | `INC-1788805056-155e` (smoke) | "the engineering team is validating that all monitoring and alerting systems are operating correctly" — an activity nobody performed | same; plus an explicit allowed answer: "no responder actions recorded yet" |
| 2026-09-07 | `INC-1788805056-155e` (smoke) | "approximately 6 seconds" for an 8-second interval — back-computed from rounded `duration_min` | queued for Day 10: quote `duration_min`, never compute from timestamps |
| 2026-09-07 | `INC-1788559916-4b4b` (Eval 1) | "Our engineering team is actively investigating" — no note records any action | second occurrence of the invented-activity failure; fix confirmed |
| 2026-09-07 | `INC-1788559916-4b4b` (Eval 1) | "detection triggered within seconds of the issue beginning" — the record has no issue-start time; detection actually took ~2 min (`for: 2m`) | queued: "What went well" may only cite record facts |
| 2026-09-07 | `INC-1788806049-78f7` (Eval 2) | "The engineering team is actively investigating the root cause" at open — third occurrence, no notes existed yet | prompt fix confirmed for Day 10 |
| 2026-09-07 | `INC-1788806049-78f7` (Eval 2) | not invented, but *upgraded*: the note's "suspect fraud dependency" became "was caused by fraud service timeouts" | queued: "preserve the responder's hedging; if a note says suspect, write suspected" |
| 2026-09-07 | `INC-1788806049-78f7` (Eval 2) | "21x normal (14.4x the 0.5% budget)" — the alert's threshold presented as a measurement | queued: "alert thresholds are not measurements; quote the summary line, not the description's constants" |
