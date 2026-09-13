# The 15-minute demo — "can you show me?"

A guided tour you can give on a screen share from a cold laptop. `./scripts/201-demo.sh`
runs the commands in this order, shows the clock, and waits for Enter between beats; this
file is what you say. The fault is real (the fraud dependency goes down), the alert windows
are real (that is why there are waits), and nothing is pre-recorded. Rehearsed and timed:
`checkpoints/day20-demo.txt`.

## Before the call (10 minutes, not on the clock)

```bash
./scripts/up.sh                       # terminal 1 — containers, cluster, collectors, drift plan
./scripts/12-loadgen.sh               # terminal 2
./scripts/33-loadgen-egift.sh         # terminal 3
./scripts/06-grafana.sh               # terminal 4 — :3000, open Platform Overview
./scripts/201-demo.sh --check         # no open tickets, three collectors, KB on the bot, traffic, AI on
```

If a collector is down it is Splunk still booting (`docker logs splunk | tail -3`, wait for
*Ansible playbook complete*, then `./scripts/100-enrich-config.sh`). Do not start the demo
with a degraded collector; the hypothesis will say so on screen.

Screen layout: terminal 1 (the driver) left, Grafana right, a Splunk tab behind it.

## The beats

**0:00 — one sentence.** *"This is a fake payments platform — card activation, gift cards, a
settlement batch — built to be broken on purpose, so I could practise the whole incident loop:
detect, diagnose, fix, learn. I'm going to break it now and we'll watch what the platform does
before I touch anything."*

**0:30 — beat 1, the platform in one screen.** Grafana: the three service rows, the health
score, the SLO burn panels, the deploy annotations. Terminal: no open incidents; the seven
KPIs with their sources. *"Every number here has a definition and a query behind it —
`docs/ops-kpis.md`. MTTD only counts incidents where the fault time is on the record."*

**1:00 — beat 2, break it.** The driver sets the fault itself (`FRAUD_SVC_DOWN=true` on activation): the
fraud check starts timing out. *"I'm not going to say what I did. Watch
the overview."* Over the next three minutes: the health row sags first (it is computed from
error rate, latency and the SLO burn, and it moves before any alert can — Day 7), then the
error-rate panel, then the Splunk histogram on the other tab shows `fraud_service_timeout`
climbing. *"The alert needs about three minutes: a 2-minute error-rate window plus a `for`
clause. That delay is deliberate; a faster alert is a noisier alert, and Day 18 was a whole day
spent deciding what deserves a page."*

**~4:00 — beat 3, the page.** A ticket exists, opened by the platform 15 seconds after the
alert. The timeline: the alert, the remediator's verdict (*no signature — tier 3, human
required*), the context, two AI drafts. *"Nobody has typed anything yet."*

**4:30 — beat 4, what the ticket already knows.** Three sources, attached in under a second:
the metrics snapshot, the deploy history (*none in six hours — so not a release*), and the log
reason histogram (*`fraud_service_timeout` in the hundreds, `issuer_declined` in the tens*).
*"This is what a responder used to spend ten minutes assembling by hand on Day 3."*

**5:00 — beat 5, the hypothesis.** Read the first section aloud. It should name the fraud
dependency, cite **kb-001** by id, list the discriminating checks the context already settles
versus the ones still to run, dismiss the look-alike (kb-002, a bad release: *no deploy in the
window*), and state the fix as the team's prior answer — *tier 3, external, no safe automated
action*. *"That last line came from a file a person wrote after INC-0001. The model is reading
the team's memory, not inventing a runbook. On Day 9 it invented one; that failure is in
`docs/ai-eval.md` with the change we made."*

**6:00 — beat 6, the copilot.** One question: *activation errors are up and the logs say
fraud_service_timeout — what is this, and is egift affected?* Watch the tool trail: alerts →
Prometheus → the log search → deploys → the answer, with every step a tool result you can
check. *"Read-only hands. It can't restart anything, can't read a secret. The allow-list is
the security boundary. And it answers the second half — egift is affected because it calls
activation — which is the question a human on the bridge would ask next."*

**7:00 — beat 7, the remediator.** Its actions log: tier 3, human, with a reason. *"It has
four signatures. A crash-looping pod it will restart on its own, once, and report if that did
not stick. A bad deploy it will propose a rollback for and wait for one word. A dependency
outage it will not touch — there is no safe action, and it says so rather than trying."* The
driver reverts the fault here (the "vendor fixed it" moment). *"Now watch: nothing else
happens by hand."*

**8:00–12:00 — the wait, which is the point.** Error rate falls within a minute; the alert
holds until its 5-minute window clears. Fill it with the two things worth seeing: the KB
entry (`kb/fraud-dependency-outage.md`: symptoms, checks, fix, tier, the seven incidents it
was learned from) and one incident write-up (`incidents/INC-0019.md` — the same fault, with
the numbers next to its three earlier runs). *"Time-to-resolve on every ticket in this repo is
bounded by the alert's own window, not by the fix. That's an honest line in the KPI table."*

**~12:00 — beat 8, resolution.** The ticket resolves itself; a resolution draft appears —
what happened, the times, what was done, quoted from the record. *"Drafts, not decisions. A
human posts it, or doesn't."*

**13:00 — beat 9, the morning brief.** `daily_report.py` runs on demand: 250 words, four
sections, every number checked against the data that produced it. It should name the
incident, its duration, kb-001, and say what needs a human (a write-up). *"This runs at 07:00
from Jenkins. It can only see what the record holds — which is the argument for keeping the
record."*

**14:00 — beat 10, close.** MTTD now has one more sample. *"The platform isn't the product.
The record is: twenty-two write-ups, the eval history with the failures kept, the seven
patterns the platform reasons from, and the KPI table with a trend. Those are in `incidents/`,
`docs/ai-eval.md`, `kb/` and `docs/ops-kpis.md`, and they're the parts I'd want you to read."*

## If it goes wrong on the call

| It | Say / do |
|---|---|
| no ticket after 6 min | *"the load generator died — that's the most common failure in this lab too"*; `./scripts/12-loadgen.sh`, and the driver keeps polling |
| hypothesis does not cite kb-001 | read section 6 anyway — *offered and ignored* vs *not offered* is a graded distinction (`kb_matches` on the record); it has happened once in twenty runs |
| copilot times out | `python3 tools/inc.py hypothesis <id>` already has the answer; the copilot is the second opinion |
| Splunk collector FAIL mid-demo | the hypothesis will say "two sources of three" — *"and that's the right behaviour: it tells you what it can't see"* |
| over 15 minutes | the waits are fixed (≈3 + 5 min); cut beats 6 or 9, never 5 or 8 |

The same tour runs on EKS with `KUBE_CONTEXT=aws-lab` after `190`; it costs about four
dollars and the logs come from CloudWatch. Save it for the second conversation.
