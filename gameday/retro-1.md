# Game day 1 — retro ("the friday afternoon special")

Run started 2026-09-09T14:44:17Z. Scenario: `gameday/scenario-1.sh` (read after the run).
Timeline: `gameday/timeline-1.md` (46 entries). Incidents: `incidents/INC-0016.md` (egift),
`incidents/INC-0017.md` (settlement). Ground truth: `gameday/.scenario-1.log`.

## Summary

Two independent faults, three minutes apart: a partner email degradation (35 % of eGift
orders failing at `send_email`, injected by a hand edit of the Deployment — no pipeline, no
annotation) and, unrelated, settlement reconciling zero records (the CronJob's env, biting
at the next tick). The platform ticketed both within 50 s of their alerts, put the right
cause on the first ticket in 2 minutes, correctly declined to act on it, and on the second
re-ran the job, failed with the job's own reason, and — after the human fixed the cause —
succeeded on its bounded retry. The responder looked at the overview first, kept the two
threads apart in writing, found fault 1's root cause from the rollout history (a revision
with no change-cause) and fault 2's from the failed pod's log, and reverted both at
14:55:51Z — **11 m 34 s after the first look**, **11 m 33 s** after the first alert.
Both tickets resolved on their alerts' own clocks (9.6 and 18.0 min).

## Timeline (merged: scenario · platform · you)

| UTC | Source | Event |
|---|---|---|
| 14:44:17 | scenario | T0 |
| 14:44:18 | scenario | **fault 1** injected: `deployment/egift EMAIL_FAIL_RATE=0.35` → rollout, revision 8, no change-cause |
| 14:47:19 | scenario | **fault 2** injected: `cronjob/settlement SETTLEMENT_FAIL_MODE=silent` (future Jobs only) |
| 14:48:35 | platform | `EgiftHighErrorRate` firing (+4 m 17 s after fault 1: ramp + `for: 2m`) |
| 14:49:05 | you | back from the walk; **Platform Overview first**: egift row red (35.4 % errors, health 30), activation green, settlement green (100, 4K records — fault 2 has not bitten yet), 0 critical alerts (the `for:` window), no deploy annotations |
| 14:49:10 | you | first hypothesis written: egift sick, activation healthy underneath — "do NOT assume" |
| 14:49:24 | platform | ticket `INC-1788965364-b5c7` (egift) — 49 s after the alert |
| 14:49:33 | platform | context: 24 % errors, no deploys in 6 h, log reasons `email_delivery_failed` 107 / `activation_failed` 32 |
| ≈14:50:00 | platform | settlement cron tick: first run in `silent` mode → self-check → exit 2 |
| 14:50:22 | platform | AI **open** draft **failed** (48.6 s) |
| 14:50:38 | platform | hypothesis: *email delivery failure*, no deploy, alternative activation cascade, medium — **right** (2 m 03 s after the alert) |
| 14:50:39 | platform | remediator: no signature → *tier 3, human required* — **right** |
| 14:50:54 | you | overview again: 1 critical alert; egift 42 %; **latency up on both services** (activation p95 484 ms, egift 681 ms); settlement still 100; no ticket visible yet |
| 14:51:14 | you | *Remediator scraped* stat 1 → 0 — went to check the remediator was alive |
| 14:52:38 | platform | `SettlementZeroRecords` firing |
| 14:53:04 | platform | ticket `INC-1788965584-fca7` (settlement) — 26 s; remediator: no signature for `ZeroRecords` → tier 3 |
| 14:53:21 | you | pod list (for the remediator): remediator fine; **egift pods 5–7 min old, everything else hours** — a rollout nobody announced; **`settlement-29816090` pod `Error` 30 s ago** — fault 2 noticed, from a pod list, not from the overview |
| 14:53:31 | platform | settlement hypothesis attached |
| 14:54:19 | you | read ticket b5c7 (context, hypothesis); read egift rollout history (rev 6/7/8, all `<none>`); read the failed settlement pod's log: `fail_mode=silent strict=True … refusing to report success: zero records` — **fault 2 cause named**; DECISION: two incidents |
| 14:55:04 | platform | `SettlementJobFailed` joins the settlement group → signature matches → remediator creates re-run job |
| 14:55:40 | you | egift revision 8 env: **`EMAIL_FAIL_RATE=0.35`** (baseline 0.01) — **fault 1 root cause named**; copilot answer read and graded; second ticket seen; DECISION: revert both |
| 14:55:51 | you | **FIX both**: `EMAIL_FAIL_RATE=0.01`; `SETTLEMENT_FAIL_MODE=none` + a manual Job from the CronJob |
| 14:55:57 | platform | remediator AUTO re-run **FAILED** (its job was created at 14:55:04, before the fix) — note quotes the job's reason; "retry once in 180 s" |
| ≈14:56:10 | platform | manual job `settlement-manual-1788965751` **Complete** (17 s) — first clean run after the fix |
| 14:57:04 | platform | remediator COOLDOWN (group update) |
| 14:59:02 | platform | egift alert resolved → ticket **resolved**, 9.6 min; resolution draft 14:59:15 |
| 14:59:14 | platform | remediator **retry 1/1 SUCCEEDED**: `settlement-remediator-1788965937` Complete, 4 517 records |
| 15:11:06 | platform | `SettlementJobFailed` ×3 clear (15-min window) → settlement ticket **resolved**, 18.0 min; resolution draft 15:11:24 |

Scribe honesty: several notes share a timestamp (14:49:05–10, 14:50:54, 14:54:19,
14:55:40, 14:58:21) — they were written in batches after each look, not one per
observation. "When" in this timeline is accurate to the batch, ±1–2 min inside it.

## Detection

**Fault 1** — alert, 4 m 17 s after injection (35 % errors within ~30 s of the rollout;
`for: 2m`; evaluation). The human saw the red row 30 s *before* the ticket existed
(14:49:05 vs 14:49:24) because the overview refreshes every 30 s and the alert had already
been firing 30 s. Would have been detected without anyone in the room: yes.

**Fault 2** — alert, 5 m 19 s after the env change, ≈2.5 min after the first affected run
(the env only applies to future Jobs; the tick was 14:50). `SettlementZeroRecords` fired
first (the job pushes `records=0` even when it refuses to report success — Day 8's
defence-in-depth working as designed), `SettlementJobFailed` two minutes later. Without
anyone in the room: yes — and *two* rules would have said so, from two different signals
(pushgateway metric, kube-state-metrics Job status).

## Diagnosis

**Egift.** Context had the answer at 14:49:33 (`email_delivery_failed` 107 vs
`activation_failed` 32, no deploys); the hypothesis said *email delivery* at 14:50:38
(**Eval 6a: right**, medium confidence, alternative correctly considered). What no tool
said: *why*. The deploy collector reported "no deploys in 6 h" — true for the pipeline,
and blind to a `kubectl set env` that rolled the Deployment. The human got the *why* from
`kubectl get pods` (young pods) → `rollout history` (revision 8, no change-cause) → the
revision's env (`EMAIL_FAIL_RATE=0.35`). That is the single most valuable finding of the
day: **a change made outside the pipeline is invisible to the enrichment**, and the
responder had to reconstruct it by hand. Human TTDiag: 5 m 44 s to the failing step
(reading the ticket), 7 m 05 s to the hand-made change.

**Copilot** (Eval 6c): asked *"Is activation affected, or is this isolated to egift's
send_email step?"* — six tools, 14.6 s. Activation half: **right** and cited (1.66 %
errors, p95 0.18 s, no alerts). Egift half: **wrong** — it concluded "not isolated to
send_email; errors are elsewhere" because the *latency* of `send_email` was normal
(92 ms). It answered an error question with a latency metric and never used `search_logs`
by reason or the step error counts. A responder who trusted it would have gone looking
elsewhere. Backlog.

**Settlement.** The failed pod's log named the cause in one line (`fail_mode=silent`,
`refusing to report success: zero records`) — the Day 8 self-check paying off a second
time. Human TTDiag 1 m 41 s from the alert. The remediator's FAILED note quoted the same
line onto the ticket at 14:55:57 — automation putting the diagnosis on the record. Its
hypothesis (Eval 6b) is graded from the record after the run.

## Recovery

Both reverts at 14:55:51 (`set env` back to the README baselines), plus a manual Job so
settlement got a success immediately rather than at the next tick. Egift recovered in
≈30 s (rollout); the alert cleared 3 m 11 s later. Settlement's first clean run was the
manual one (≈14:56:10); the remediator's bounded retry at 14:59:14 was the second — a
human fixed the cause, automation finished the recovery, and the ticket says so in order.
The ticket itself stayed open until 15:11:06 because `SettlementJobFailed` counts failed
Jobs for 15 minutes: **15 of the 18 minutes were the alert's window, not the outage.**

What a company would do: egift — a ticket with the email provider, a retry queue for
`send_email`, and an answer to "who changed the Deployment at 14:44 and why is it not in
git"; settlement — the same "who changed it", and finance told that the 14:50 and 14:55
runs reconciled nothing before they ask.

## What went well

- Overview first, and it pulled correctly: one red row, and the responder wrote "do NOT
  assume" about the healthy row underneath before touching anything.
- The two threads were kept apart in writing from 14:50:54 ("two different symptoms") and
  formally at 14:54:19 ("two incidents") — the anchoring trap was named before it could bite.
- The remediator behaved exactly per policy on both tickets: declined egift (no signature),
  re-ran settlement, reported the real outcome, bounded its retry, cooled down, and its
  retry succeeded once the cause was gone.
- Both AI hypotheses arrived inside 2 minutes; the egift one was right.
- Both resolution drafts generated.

## What went badly

- **Fault 2 was found from a pod list, not from the overview.** The responder went to
  `kubectl get pods` to check the remediator (a transient red stat) and *happened* to see
  the `Error` pod. The overview would have shown settlement red by ~14:53; the responder
  did not go back to it after 14:50:54. In a real bridge that is luck, not process.
- **The enrichment could not see the change.** "No deploys in 6 h" was true and useless; the
  cause was a Deployment revision with no change-cause that only `rollout history` knew about.
- The copilot's conclusion on the egift step was wrong (latency used as an error signal).
- The hypothesis's "suggested next checks" 1 and 2 were **invented commands**
  (`kubectl exec deploy/kps-prometheus -- promql …` does not exist).
- The AI open-draft call failed (48.6 s) on the egift ticket — the resolution draft later
  succeeded; the cause is not on the record.
- The Tempo trace check (PDF step 1: "verify against a trace") was not done.
- Scribing in batches; a 2-minute gap (14:51:14 → 14:53:21) with no line.

## The three game-day questions

**Did anything you built mislead you?** Four things, in descending seriousness. (1) The
deploy collector's "no deploys" — not wrong, but it answered a narrower question than it
appeared to, and a responder who trusted it would have stopped looking for a change.
(2) The copilot's "not isolated to send_email" — wrong, confidently, with citations.
(3) Two invented commands in the hypothesis's next steps. (4) *Remediator scraped* going
red for one scrape, which cost two minutes — though those two minutes found fault 2.
And one noise item: nine `kps-*` cluster alerts (etcd, scheduler, proxy TargetDown — the
kind cluster's permanent false positives, routed to null) fill the status screen during
an incident.

**Where did you look first, and was that right?** The overview; right. It showed one
unhealthy row and the second was genuinely still green (fault 2 had not run yet). The
failure was not *where first* but *not going back*: the overview was looked at twice in
the first two minutes and never again. Rule for next time: overview every 3 minutes,
as a scribe line, whatever else is happening.

**What would a second responder have needed?** Reading `timeline-1.md` from 20 minutes in
(15:04): they would know both faults, both causes, both fixes, both expectations, and the
remediator's state — the timeline is good. They would *not* know: the copilot transcript
path; whether the egift rollout from the fix had completed; why the remediator stat went
red; what happened between 14:51 and 14:53; and the batching means they could not tell
which observation came first inside a batch. Fixes: one note per look, the transcript path
in the copilot note, and "expect X by HH:MM" lines (the one at 14:58:21 was the most useful
line in the file for a newcomer).

## Follow-ups (backlog)

- [ ] **Enrichment: a "kube changes" collector** — Deployment/CronJob revisions in the last
      30 min with their change-cause (or `<none>`), from the API, not from Grafana annotations.
      A hand `kubectl set env` becomes "revision 8 at 14:44:18, no change-cause" on the
      ticket. The most valuable single item from the day.
- [ ] Copilot SYSTEM rule: *latency is not an error signal; for "is step X failing" use
      `search_logs` by reason or error counts by step* — and re-ask the same question as Eval 6c-bis.
- [ ] Hypothesis prompt: next checks may only name tools that exist (`tools/inc.py`,
      `tools/copilot.py`, Grafana Explore, Splunk search); add the fact to `PLATFORM_FACTS`.
- [ ] Bot: investigate the failed open draft (48.6 s ≈ a timeout?) — `kubectl logs deploy/incident-bot`
      around 14:50:22; add one retry for `ai_draft` failures.
- [ ] `142 status` / overview: filter null-routed `kps-*` alerts from the firing list.
- [ ] Overview: *Remediator scraped* as `max_over_time(up[5m])`, not the instant value.
- [ ] Remediator: when a group opens with `SettlementZeroRecords`, the tier-3 note should say
      *no signature for ZeroRecords; JobFailed would match if it joins* — it did two minutes later,
      and the two notes read as a contradiction.
- [ ] Bridge habit: overview every 3 minutes as a scribe line; one note per look; the Tempo
      trace as a standard step for any egift error incident.
- [ ] `SettlementJobFailed`'s 15-minute window keeps a fixed incident open for 15 minutes —
      consider `resolve` semantics keyed on a *later successful* run (a `settlement_last_success_timestamp > start_time` clause).
- [ ] `k8s/alerts.yaml`: `SettlementZeroRecords`' description still says "Kubernetes says Succeeded … 'settlement complete'" — false since Day 8; the hypothesis quoted it as fact (Eval 6b). Runbook rot inside a rule.
- [ ] Enrichment logs collector: `app.status=error` misses the settlement job's `level=ERROR reason=zero_records` line (no `status` field) — search `OR app.level=ERROR`. The one line that would have ended INC-0017 was invisible to the bot.
- [ ] Unexplained: latency rose on **both** services at 14:50 (activation p95 173 → 484 ms) for a
      few minutes while only egift had errors. The egift rollout? The VM? Check node CPU for 14:48–14:52.

## Numbers for `docs/ops-kpis.md`

| # | detected by | TTD | TTDiag | TTR | mode |
|---|---|---|---|---|---|
| 0016 | alert `EgiftHighErrorRate` | 4 m 17 s (fault → alert) | bot **2 m 03 s** (right: email step); human 5 m 44 s to the step, **7 m 05 s to the hand-made change** | alert → resolved 10 m 27 s; fix → resolved 3 m 11 s; fault → resolved 14 m 44 s | manual (remediator correctly declined) |
| 0017 | alert `SettlementZeroRecords` (+`JobFailed` 2 min later) | 5 m 19 s from the env change, ≈2.5 min from the first affected run | human **1 m 41 s** (the job's own log line); bot hypothesis at +53 s | alert → resolved 18 m 28 s (15 of them the alert's window); fix → first clean run ≈19 s | manual cause fix + **auto** tier-1 retry succeeded |
