# Remediation policy — what may run on its own, what needs a human, and how we know

Written before the remediator was built (Day 12), because the control framework matters
more than the code. An automation that restarts the wrong thing during an incident is a
second incident.

## The three tiers

| Tier | Meaning | Runs when | In this lab |
|---|---|---|---|
| **1 · auto** | Safe, reversible, well understood. Runs immediately, **notifies after** — on the incident timeline, with the result. | the signature matches | delete a crash-looping pod (the Deployment replaces it); re-run a failed settlement job (idempotent here) |
| **2 · approve** | The correct action is known but it has blast radius or reverses someone's work. **Prepared** automatically, **executed on one human yes** — a capability token, not a chat message. | the signature matches → a proposal with rationale and a token lands on the timeline; a human posts the token back | roll back `activation` when an error spike follows a deploy within 30 minutes |
| **3 · human** | Novel, destructive, or a fix the platform cannot safely take. Automation only assembles context and says so. | no signature matches | the fraud dependency outage: the fix (restore the dependency) is not an action this platform can take. The remediator's only job is to write "no signature matched — human required" on the ticket, fast |

**The tier lives with the action, not the incident.** The same alert can lead to tier 2
(error spike after a deploy) or tier 3 (error spike with no deploy) — the *signature*
decides, and a signature is a precise condition, not a vibe.

## The promotion rule

An action moves from tier 2 to tier 1 only after it has run correctly **under approval at
least five times**, with no false positive, and the team agrees in writing (a line in this
file with the date and the incidents). Nothing starts at tier 1 except actions whose
failure mode is "nothing happened" — deleting a pod a Deployment will replace, re-running
a job that is idempotent. Demotion is immediate: one wrong action and the tier goes up
until the signature is fixed.

That promotion path is the honest version of "self-healing". Systems that skip it become
famous in post-mortems.

## What every action must do, regardless of tier

1. **Write to the incident timeline** — proposed, approved, declined, executed, failed,
   skipped (cooldown). During a bridge, "what has the automation already done?" must
   have an instant answer. Notes are prefixed `[remediator]`.
2. **Verify the condition before acting.** "The alert says crash-loop" is not the same as
   "this pod is in CrashLoopBackOff right now" — check, then act, then re-check.
3. **Report the outcome, not just the attempt.** A re-run that also crashed is a failure
   note, not a success note. A restart after which the pod crash-loops again is
   *"restart did not stick — this is real"*, which is the most useful sentence a tier-1
   action can write.
4. **Cool down.** One action per signature per 10 minutes. Without it, delete → crash →
   alert → delete is a loop that looks like activity.
5. **Bounded retry.** Tier 1 may retry **once**, after a delay, if the incident is still
   open. Never more: a second failure is a human's problem.
6. **Least privilege.** The remediator's ServiceAccount can delete pods, create jobs, and
   patch **one** deployment, in **one** namespace. It cannot read secrets, cannot touch
   egift or settlement's Deployment, cannot delete anything but pods. Proven with
   `kubectl auth can-i --as=system:serviceaccount:payments:remediator` in the checkpoint.
7. **Metrics.** `remediation_actions_total{signature,mode,result}` on the overview
   dashboard. An automation that fails silently is the settlement job all over again.

## The signatures (Day 12)

| id | detects | action | tier | rationale |
|---|---|---|---|---|
| `pod-crashloop` | `PaymentsPodCrashLooping` (our rule: `CrashLoopBackOff` seen in 5 min **or** 3+ restarts in 10 min, the pod must still exist, `for: 1m`, service label from the pod name) | delete **that** pod, after confirming it is crash-looping right now | 1 | the Deployment replaces it; strictly reversible; if it crash-loops again the note says so |
| `settlement-crash` | `SettlementJobFailed` | create a Job from the CronJob, wait for it, report; retry once after 3 min | 1 | settlement is idempotent on this platform (`pushadd`, `last_success` only on real success — Day 9) |
| `post-deploy-errors` | `ActivationHighErrorRate` **and** a deploy of activation within the last 30 min (Grafana annotations, via the bot's collector) | `rollout undo deployment/activation` | 2 | rollback is the known fix but reverses someone's release — a human confirms with the token |
| — | `ActivationHighErrorRate` with **no** recent deploy (the fraud outage) | none | 3 | the fix is outside the platform; page a human, fast |

## What we learned running it (filled in during the drills)

- Tier 1, crash-loop (INC-0012): the restart masked nothing — the replacement pod crash-looped identically and the remediator said so 91 s later ("restart did NOT stick … this is real"). The value of tier 1 here was the *sentence*, not the restart. Three earlier attempts were refused by the pre-action check (a ghost alert for a deleted pod; twice a truncated pod document) — three refusals, zero wrong actions, every reason on the ticket. Rule 2 ("verify the condition before acting") paid for itself on day one.
- Tier 1, settlement (INC-0013): honest FAILED → announced bounded retry → cause fixed by a human inside the window → retry succeeded, `last_success` recovered, nobody ran `kubectl create job`. The first failure was the tool's (kubectl API discovery ate the 30 s timeout — B12), which is the strongest argument for rule 3: the note said "could not create job … timeout", not "re-run started". Two cooldown skips in between, each explained on the ticket.
- Tier 2, rollback: _alert → proposal → approval → recovery in N s, vs the Day 6 pipeline's N — INC-0014_
- Tier 3: _the fraud outage got "human required" on the ticket within N s of opening_

## Promotion log

| Date | Action | From → to | Evidence | Agreed by |
|---|---|---|---|---|
| — | — | — | — | — |
