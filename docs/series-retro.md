# The series — a retro

Written on Day 20, the way every incident in this repo ends: what happened, what compounded,
what misled, what I would do differently, and the one sentence I now believe with evidence.
The numbers are in `docs/ops-kpis.md`; the incidents in `incidents/`; the record of what the
AI got wrong in `docs/ai-eval.md`; the 265 things the guide got wrong in `CORRECTIONS-DAY*.md`.

## What compounded fastest

**The write-up → KB → AI chain was the multiplier.** Each link existed for a few days on its
own and did little; together they changed the numbers. Day 3's ten-minute Splunk search
became a saved query (Day 3), then a collector on every ticket (Day 10), then a row the
hypothesis reasons from (Day 10), then a KB entry with a tier (Day 17), and on Day 19 the
model cited that entry by id at high confidence on a cloud ticket, deciding on rows the
collector fetched from CloudWatch. The chain is: *a person writes down what happened → the
platform fetches it next time → the model reads it → the person corrects it.* INC-0021 is the
proof that the last link matters as much as the first: one wrong sentence in kb-004 sent the
hypothesis to the wrong entry, and the retro fixed the sentence.

**The record compounded second.** The ticket (Day 8) became the place everything writes to —
the remediator's notes, the drafts, the context, the scribe, the retro's ground truth — and
by Day 18 a 250-word brief could be generated from it and checked against it. "The report can
only see what the record holds" was the PDF's line for Day 18; it turned out to be the moral
of the whole series, because every tool built after Day 8 was only as good as the record it
read.

**The corrections habit compounded quietly.** Running every step and writing down where the
guide was wrong (B), where I chose differently (D), and what I noticed (N) produced 265
items — and the habit of *not trusting the tooling I was handed* is the one that found the
misleading health score (Day 7), the routing that sent nine false positives to the bot (Day
8), the copilot allow-list that let a rollback through (Day 11), and the KB sentence (Day 19).

## What I would resequence

- **The knowledge base before the copilot.** The KB (Day 17) is a ConfigMap and a prompt
  block; it could have existed on Day 10 next to the first hypothesis, and the copilot (Day
  11) would have had memory from birth. Eight days of hypotheses were graded without it.
- **Alert hygiene before the game day, not after.** Day 14's game day ran with 155 chart rules
  unjudged and warnings paging. Day 18's audit was a day's work; done on Day 9 it would have
  made every drill's routing honest.
- **AWS guardrails on Day 1, the cluster on Day 16 as it was.** Creating the account on Day
  14 was right (the credit window); the *budget alarm and SSO* could have been Day 1's
  homework so that Day 15 was only Terraform.
- **The Friday drill from week 1.** Nothing keeps the loops warm like one fault a week; it
  was implicit until Day 20 wrote it into the README.

## The hardest day, and why

**Day 13** (infrastructure as code) had the most corrections (23) and the longest incident
(INC-0015: 59 minutes from change to repair, 48 of them fixing the tooling). It was hardest
because it was the first day the *tooling* was the incident: the helm provider's ghost, state
that held secrets, a plan that could not see live drift. Day 17 brought the same ghost back
(B9), and Day 19's warm start lost an hour to it. The lesson was not about Terraform; it was
that a platform that cannot see its own changes is the one class of incident nothing alerts
on, and it took a nightly job, not a rule, to catch it.

**Day 19** was the most *demanding* — three faults live at once, one responder, a cluster
three hours old — and the least surprising, which is the point of the eighteen days before it.

## What misled me, across the series

| day | what | the fix |
|---|---|---|
| 7 | a health score that read 94 at 10 % errors | a formula that moves, with the worked example in `docs/health-score.md` |
| 8 | Watchdog and kube-system false positives routed to the bot | the null route, and Day 18's judgment table |
| 9 | an AI draft that invented a procedure and an activity | "no responder actions recorded" as an allowed answer; the failures table |
| 10 | a hypothesis that blamed the rollback for the outage it fixed | quote `duration_min`, never compute from timestamps; rank events by time |
| 13 | `terraform plan` that could not see drift | the provider made to compare live state (B8) |
| 14 | a runbook line that drifted | the audit habit (`141-readme-audit.sh`) |
| 18 | Grafana annotations silently failing since Day 13 | the fixed secret name, and a shout in the pipeline on failure |
| 19 | kb-004's "a crash pushes nothing"; a deploys collector that only reads annotations | the entry corrected; the collector's blindness is backlog line one |

None of these were missing tooling. All of them were tooling that existed and was wrong, and
the retro question that found each one — *did anything you built mislead you?* — is the one I
will keep asking.

## The thesis, with evidence

**Reliability is engineered in loops — detect, diagnose, fix, learn — and modern tooling, AI
included, is about tightening each loop without letting go of the wheel.**

The evidence, one number per loop: *detect* went from a person on a dashboard (0002, 0003) to
3 m 35 s / 3 m 40 s / 2 m 49 s on a cluster three hours old, with 15 seconds to a ticket
(0020–0022). *Diagnose* went from ten minutes of writing a search (0001) to 43 seconds on
the ticket (0009), 31 seconds before the alert (0011), and cited-by-id at high confidence
(0019, 0022). *Fix* went from minutes of a human at a keyboard (0006) to one 35-second
decision (0014) to zero operator actions (0021). *Learn* is the KB's `learned_from` lists and
the ten evals with their failures kept. And "without letting go of the wheel" is the
remediator's tier 3 line on the two incidents it correctly refused, the copilot's allow-list,
and the human who overruled a medium-confidence hypothesis at 20:40Z on Day 19 because
`issuer_declined` at 3 % is baseline noise — a judgment no tool in the repo could make.

## Standing habits

In the README, where they will be seen: the Friday drill, feed the KB, read the daily
report, warm-start AWS monthly. The series ends the way a good incident does — with a written
record and named follow-ups (`docs/first-90-days.md`, and the backlog in every retro).
