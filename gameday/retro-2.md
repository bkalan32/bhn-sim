# Game day 2 — retro (Day 19, on EKS)

Run started 2026-09-12T20:33:06Z. Scenario: `gameday/scenario-2.sh` (read *after* the run).
Timeline: `gameday/timeline-2.md`. Incidents: `incidents/INC-0020.md`, `incidents/INC-0021.md`, `incidents/INC-0022.md`.
Closing brief: `reports/daily/2026-09-12-eks-closing.md`. Grades: `docs/ai-eval.md` Eval 10.

## Summary

Three faults in nine minutes on a cluster that had existed for three hours: a creeping
latency with no errors (an unpipelined config change), a settlement crash (the rehearsed
pattern, with a signature and a KB entry), and a partner email failure (known, external).
The platform alerted on all three inside 3 m 40 s, ticketed each within 15 s, attached three
sources to every ticket for the first time in the cloud, and closed every ticket itself. The
human touched the platform three times — one revert, one vendor reset, one partner reset —
and resolved nothing by hand. From first fault to last resolution: 32 m 40 s.

## Timeline (merged: scenario · platform · you)

| UTC | Source | Event |
|---|---|---|
| 20:33:06 | scenario | fault 1: activation `BASE_LATENCY_MS=600` (pods rolled) |
| 20:36:41 | platform | `ActivationLatencyBudgetBurn` firing (warning) — 3 m 35 s; 1h burn 17.2× |
| 20:36:56 | platform | `INC-…-72a4` opened; remediator tier 3 → human; context 790 ms (3/3, logs = CloudWatch) |
| 20:37:28 | platform | hypothesis: "slow issuer", medium — wrong lead (baseline noise) |
| 20:36–20:38 | you | back from the walk; first look = `192 status` (the tier-3 line showed the ticket before `list open` did) |
| 20:37:51 | scenario | fault 2: settlement `SETTLEMENT_FAIL_MODE=crash` |
| 20:40:55 | you | read hypothesis + context; disagreed with the lead; went to the deployment |
| 20:41:46 | platform | `INC-…-ac0f` opened on `SettlementZeroRecords` (the crash pushed 0); tier 3 on that alert |
| 20:42:07 | scenario | fault 3: egift `EMAIL_FAIL_RATE=0.5` — three faults live |
| 20:42:16 | platform | settlement hypothesis: kb-005 (misled by kb-004's own text) |
| 20:43:46 | platform | `SettlementJobFailed` joins the settlement ticket |
| 20:44:02 | platform | **AUTO** `settlement-crash` re-run → FAILED (`db_unreachable`); "retry once in 180 s" |
| 20:44:56 | platform | `EgiftHighErrorRate` firing — 2 m 49 s |
| 20:45:11 | platform | `INC-…-ce45` opened; tier 3; context 784 ms (`email_delivery_failed 82` from CloudWatch) |
| 20:45:44 | platform | egift hypothesis: **kb-003, high, "the email partner must recover", tier 3** |
| ≈20:46 | you | copilot: 18 hands, 65 s → `BASE_LATENCY_MS: 600`, pods 8 m old, no deploy, no dependency |
| 20:47:19 | platform | **AUTO** retry 1/1 → FAILED; cooldown 600 s, "a human's problem" |
| 20:47:37 | you | root cause + limit + decision on the activation record |
| 20:47:50 | you | **fault 1 reverted** (`BASE_LATENCY_MS=80`), rollout done ≈20:48:20 |
| 20:48:33 | you | `192 status`: three tickets open, two failed re-runs on record — the settlement one is now the vendor's |
| 20:50:00 | platform | cron job cut from the old template (19 s before the reset) → will fail |
| 20:50:19 | you (as vendor) | **fault 2 reset** (`SETTLEMENT_FAIL_MODE=none`), note on the ticket |
| 20:51:46 | platform | `SettlementStale` joins (the 19 seconds) |
| 20:52:12 | you | partner ticket posted as a note on the egift record |
| 20:52:56 | platform | **activation resolved** (16.0 min; fix → resolved 5 min) |
| ≈20:53 | you (as partner) | **fault 3 reset** (`EMAIL_FAIL_RATE=0.01`) |
| 20:55:00 | platform | cron run **Complete**, 11 s — first clean run, no human action |
| 20:55:11 | platform | **egift resolved** (10.0 min; fix → resolved 2 min) |
| 20:59:34 | you | decided *not* to delete failed jobs or resolve by hand: the rule's 900-s window closes it |
| 21:02:02 | platform | AUTO after cooldown → re-ran settlement, succeeded (5 639 records) — on a service healthy for 7 min |
| 21:05:46 | platform | **settlement resolved** (24.0 min; fix → resolved 15.5 min, the window) |
| 21:06:58 | you | `192 verify`: 0 of 3 faults live, no open incidents, three drafts, 13/2/2 notes |
| ≈21:09 | platform | closing brief: 170 words, complete, all three named, no untraceable numbers |

## Detection

All three by alert, none by a human, none by the overview (which was open on :3001 and
looked at once). Fault 1: the latency-SLO burn, **3 m 35 s** — the only rule that *can* see
"slow but fine", and a warning by design: no page, a ticket. It fired far sooner than the
9 minutes the rule's maths gives on kind because the cluster's "1h" window was thirty minutes
old — a fresh cluster has short memory, in both directions (it also cleared 5 min after the
revert). Fault 2: `SettlementZeroRecords` at **3 m 40 s**, not `SettlementJobFailed` — a
crash pushes 0 records before it exits (Day 8's fix), so the quiet rule caught the loud fault
first and `JobFailed` came two minutes behind. Fault 3: `EgiftHighErrorRate` at **2 m 49 s**
(INC-0016 at 35 %: 4 m 17 s; twice the failure rate, two thirds of the time). Alert → ticket:
15 s, 15 s, 15 s — the fourth game/drill in a row at the same number.

## Diagnosis

Three hypotheses, three different grades, and the grade tracked how much the team had
written down. **Egift (kb-003): right, high, first try** — cited by id, the look-alike
dismissed on its documented discriminator, the escalation stated as tier 3 in the team's
words; the decisive rows came from CloudWatch. **Settlement: wrong entry (kb-005 for a kb-004
fault) because the KB was wrong** — kb-004 said "a crash pushes nothing", and a crash pushes
0; the model followed the discriminator it was given. **Activation: wrong lead, honest
confidence** — "slow issuer" from the 3 % baseline declines; nothing in its input could show
the config change (no env, no rollout history; the deploys collector reads annotations
only). The copilot's trail held completely: prometheus → logs (SPL → Insights, live) →
deploys → `kubectl_get`, and the last hand found the env var and the pod age; 65 s and 74 k
tokens for the answer. Where *you* got each cause: activation from the copilot at ≈20:46
(≈13 min after the fault, 10 after the alert — the hypothesis and context were read first,
correctly); settlement from the remediator's own notes (the signature *is* the diagnosis,
plus `db_unreachable` on the job); egift from the hypothesis at first read.

## Recovery

You ran three commands on the platform in 33 minutes, one per fault: a revert of an
unpipelined change (the operator's decision, with the limit written down), a vendor reset
(the scenario's role, taken after the second automated failure and not before), and a
partner "recovery". The remediator did what its policy says, in full and on the record:
re-run, bounded retry, cooldown, hand-off — then, after the cooldown, one re-run too many on
a stale alert. Every ticket was closed by the platform on its alert windows; the settlement
one took 15.5 min after the fix because `SettlementJobFailed` counts failed Job objects for
15 min and four were sitting there — you chose to let the rule drain rather than delete
jobs, and wrote down why. At a company: the revert waits five minutes for the author to
answer; the vendor reset is a phone call; the partner reset is a ticket on their side and a
retry queue on ours.

## What went well

- Three collectors on every cloud ticket — INC-0018's follow-up closed, and the third source decided the egift case.
- The tier-1 policy, end to end, readable on one timeline; the ticket closed with no human resolve.
- The copilot on EKS, on the first try, with a translated logs query, found the one fact the ticket lacked.
- Warning stayed a ticket; critical stayed critical; the remediator declined the two it must decline and said why.
- The scribe: 12 entries, every decision with its reason, including the two "not acting" ones.

## What went badly

- The hypothesis had no chance on fault 1: the deployment's env and rollout age are not in its input, and the deploys collector is blind to hand changes — third incident in the series (0015, 0016, 0020).
- kb-004 misled the settlement hypothesis with a wrong discriminator; the alert pair cannot tell crash from silent, and the one fact that can (the job's log line) is not in the hypothesis' input.
- The remediator re-ran settlement at 21:02 on alert debris — `detect` never asked the service whether it was already healthy.
- A critical (egift) waited 7 minutes behind a warning (activation) that was already in hand; with one responder the triage order was wrong for three minutes.
- The closing brief said "tier3/human" for all three and "Deploys: none in 24h" — it reads the remediator's *first* verdict and the annotations, so the machine's incident reads like a human's and two rollouts vanished.
- The warm-start script printed 6 minutes for a ~121-minute start (clock reset by `--from`); fixed before the number went anywhere.

## The three game-day questions

**Did anything you built mislead you?** Three things, all now backlog lines: the KB entry
(kb-004's "a crash pushes nothing"), which sent the settlement hypothesis to the wrong
entry; the deploys collector's "no deploys in 6h", which is true of *annotations* and false
of the cluster, and which the closing brief repeated; and `SettlementJobFailed`'s tail, which
misled not the human (who read the rule) but the remediator (which did not). The hypothesis'
"slow issuer" was a wrong guess, not a misleading tool — it was labelled *medium* and the
reason was visible in its own evidence.

**Where did you look first, and was that right?** `192 status` — the second responder's
view: open tickets, firing alerts, the remediator's last actions, four health lines. Right,
and it stayed right for the whole hour: it was the remediator's tier-3 line that revealed
the first ticket fifteen seconds before the ticket list did, and at 20:48 it showed all
three incidents and both failed re-runs in one screen. The overview on :3001 was opened
once and not needed. The one thing `status` lacks is *triage order* — it lists tickets by
time, and the critical sat below the warning.

**What would a second responder have needed?** Reading `timeline-2.md` cold: they could
have taken the egift ticket at 20:45 with nothing but the hypothesis (it says what to do),
and the settlement one needed no one until 20:50. What they would have missed: the copilot's
transcript is not on the record (its conclusion is, as a note at 20:47:37); the two
backfilled entries (21:08) are honest but late; and nothing says which terminal had
`KUBE_CONTEXT` exported — a second responder on kind would have seen a healthy platform.

## Follow-ups (backlog)

- [ ] deploys collector reads rollout history / ReplicaSet age, not only annotations (the week-3 backlog line, now with three incidents behind it)
- [ ] hypothesis input: deployment env + pod age; re-draft when a new alert name joins the ticket
- [x] kb-004/kb-005 discriminator corrected: the alert pair is identical for crash and silent; the job's last log line decides (code done)
- [ ] settlement hypothesis input: the newest job's last log line
- [ ] `settlement-crash` `detect`: skip when `settlement_last_success_timestamp` is recent — "already recovered"
- [ ] `192 status` / `inc.py list open`: critical first, plus "minutes since last human note"
- [ ] daily report: per-incident numbers from the record, remediation *mode* from the remediator's last action not its first, deploys from the cluster
- [ ] copilot transcript → a note on the ticket when the question names an incident (one flag)
- [ ] `send_email` retry queue (kb-003's real fix; since INC-0003)

## Numbers for `docs/ops-kpis.md`

| # | detected by | TTD | TTDiag | TTR | mode |
|---|---|---|---|---|---|
| 0020 | `ActivationLatencyBudgetBurn` (warning) | 3 m 35 s | bot wrong (+31 s, medium); copilot right ≈13 min from the fault | 16.0 min (fix → 5 min) | manual revert; remediator tier 3 (correct) |
| 0021 | `SettlementZeroRecords`, then `JobFailed` +2 m | 3 m 40 s | signature +16 s after `JobFailed`; bot hypothesis wrong entry (KB error) | 24.0 min (fix → first clean run 5 min; → resolved 15.5 min, the window) | **auto** tier 1 ×2 failed → vendor reset → cron clean → auto succeeded (stale) |
| 0022 | `EgiftHighErrorRate` (critical) | 2 m 49 s | bot right, kb-003, +33 s, high | 10.0 min (fix → 2 min) | manual escalate; remediator tier 3 (correct) |

## The graduation questions (Day 19)

**Which of the three did the platform handle best, and why?**

Settlement — and not because it was easiest, but because it was the most *written down*: a
service that reports its own status (Day 5), a self-check that made the quiet failure loud
(Day 8), a signature with a bounded retry and a cooldown (Day 12), a KB entry with a tier
(Day 17), an alert whose window is documented in its own comment (Day 12). Two automated
re-runs, one vendor call, one clean run, a ticket closed by its rule — 24 minutes with zero
operator actions. Its two defects were also the most *specific*: a wrong sentence in kb-004
and a `detect` that reads the alert instead of the service. Automation quality tracked
pattern maturity exactly; the timestamps are 20:44:02, 20:47:19, 20:50:19, 20:55:00,
21:05:46.

**Where were you still essential?**

At the two ends of the known. The ambiguous case (activation): the platform could say *slow,
not failing, not kb-001, not a deploy it can see* — and stop; the copilot could find the
changed env var; only a person could decide that an unclaimed config change gets reverted and
write down that the lab knows what and when but not who or why. The external case (egift):
the platform said "partner, tier 3, escalate" perfectly and could do nothing else; the
ticket that leaves the building is a human's, as is the judgement that it outranked the
warning already in hand. Machines for the known, humans for the ambiguous and the external —
with this run's timestamps as the evidence: the machine's incident had 0 operator actions,
the other two had one each, and both of those were decisions rather than commands.

**MTTD / MTTR against game day 1 and the drills** — the dataset, closed:

| incident | fault | TTD | TTR | handled by |
|---|---|---|---|---|
| INC-0016 (GD1) | partner email 35 % | 4 m 17 s | 10 m 27 s | human (tier 3) |
| INC-0017 (GD1) | settlement zero records | 5 m 19 s | 18 m 28 s | human fix + auto retry |
| INC-0020 (GD2) | creeping latency | 3 m 35 s | 16 m 00 s | human (tier 3; copilot diagnosis) |
| INC-0021 (GD2) | settlement crash | 3 m 40 s | 24 m 00 s (fix → clean run 5 m) | **auto** tier 1 + vendor |
| INC-0022 (GD2) | partner email 50 % | 2 m 49 s | 10 m 00 s | human (tier 3, escalated) |

Detection improved on both repeats (email 4 m 17 s → 2 m 49 s; settlement 5 m 19 s → 3 m 40 s)
and the new fault class was caught by the rule built for it a day earlier. TTR is bounded by
alert windows, not by fixes — the honest line from Day 14 still holds (fix → resolved: 5, 15.5,
2 min; fix → healthy: seconds, 5 min, seconds). What changed is *who* recovered: GD1 was two
manual fixes and one auto retry; GD2 was one manual revert, one escalation, and one incident
where the operator ran nothing.

**What broke because it was AWS?** (→ `docs/eks-notes.md`, papercuts)

Nothing during the game — Pod Identity, CloudWatch, the ECR images, the API-server proxy all
worked first time. The friction was all in the warm start: 23 minutes of AWS API calls
through the WSL DNS relay for a network root that had nothing to change, the helm provider's
"inconsistent result after apply" ghost on the platform root (third time in the series), and a
kind hiccup at the image phase because the cluster the images come *from* is the laptop's.
Details, minutes and fixes in the papercuts table.
