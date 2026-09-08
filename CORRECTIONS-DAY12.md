# Day 12 — Corrections Log

Source: `day12autoremediation.pdf` · Verified 8 September 2026 against the running lab.

---

## [BUG] B1 — The RBAC the PDF says "do not skip" is never written

**Guide, Step 2:** *"Give its ServiceAccount a Role limited to pods (delete), jobs (create)
and the one deployment (rollback) in payments only. Twenty lines of YAML … Do not skip it."*
There is no YAML, and the Deployment snippet has no `serviceAccountName`, so the pod runs as
`default` — which in a kind cluster can do nothing, so every action fails with `forbidden`
(the PDF's own troubleshooting note, presented as "your RBAC working"). **Substitute:**
`k8s/remediator.yaml` — ServiceAccount, Role, RoleBinding, with every verb mapped to one
action: pods get/list/delete, pods/log get, cronjobs get (`settlement` only), jobs
get/list/watch/create, deployments get/watch/patch (**`activation` only**), replicasets
get/list. `120-remediator-config.sh --check` asks the API server what that identity may do
(`kubectl auth can-i --as=system:serviceaccount:payments:remediator`) — fourteen yes/no
answers, including *no* to secrets, *no* to deleting deployments, *no* to egift's Deployment,
*no* outside `payments`. The checkpoint runs it.

---

## [BUG] B2 — `delete_pod` deletes the wrong pod

**Guide, Step 2:** `kubectl get pods --no-headers | awk '$4>3 {print $1}' | head -1 | xargs
kubectl delete pod` — "any pod in the namespace with more than 3 restarts, first one wins",
parsed from human-readable output through a shell. The activation pods carry restart counts
from a week of drills; the first match is as likely a healthy pod as the crash-looping one.
And it is a shell pipeline built from strings. **Substitute:** the alert names the pod
(`{{ $labels.pod }}`); the remediator `get`s *that* pod, confirms a container is in
`CrashLoopBackOff` **right now**, and deletes it — or refuses with the reason ("the alert may
be stale"). kubectl runs as an argv list, never through a shell.

---

## [BUG] B3 — Actions run inside the webhook handler

**Guide, Step 2:** `execute(sig)` inside `async def receive`. A rollback is `rollout undo` +
`rollout status --timeout=180s`; a re-run waits for a Job. Alertmanager's webhook timeout is
seconds; it retries; the same action runs twice. Same class as CORRECTIONS-DAY9 B1 and DAY10
B1, with a kubectl instead of a model. **Substitute:** the handler queues a thread and returns.
Approval is different: the human wants the *result*, so `/approve` runs the action in a
threadpool and answers when it is done.

---

## [BUG] B4 — `_note` writes on "the first open incident"

`open_ids[:1]` — whichever ticket happens to be first. During the tier-2 drill two tickets are
open (activation and the egift cascade); during the settlement drill, possibly a third. The
remediator would narrate a rollback on the egift ticket. **Substitute:** the note goes to the
open incident **for the service in the webhook**, and — because the fan-out reaches the bot
and the remediator in the same instant — the lookup waits up to 60 s for the bot to open it.
The tests prove the note lands on the right record with two open.

---

## [BUG] B5 — The crash-loop signature can never fire, and the drill takes egift down

Two problems. `KubePodCrashLooping` from kube-prometheus-stack carries no `service` label, so
the Day 8 route (`service =~ …`) sends it to `null`; neither the bot nor the remediator ever
sees it. It also has `for: 15m`. And the drill — "patch egift's command to `["false"]`" —
crash-loops **both** egift pods: a real outage, cascading nothing but breaking a customer
flow, to test a pod restart. **Substitute:** our own `PaymentsPodCrashLooping` (`for: 2m`,
service label derived from the pod name with `label_replace`), and a throwaway Deployment
`crashtest` for the drill, listed in the regex and the route as a named lab fixture.

---

## [BUG] B6 — No cooldown, no bounded retry, no expiry, no dedupe

The PDF adds a cooldown "when you see the loop". You will see it in the first minute: delete →
Deployment replaces → crash-loops → alert (still firing, group update) → delete. Also missing:
tokens never expire (a proposal from Tuesday is approvable on Friday, against a different
incident); the same proposal is re-posted on every group update; a re-run that fails is
reported once and forgotten. **Substitute:** cooldown per signature (10 min, and a note
saying so — "if the alert is still firing after that, it is real"), bounded retry (once,
after 180 s, only if the incident is still open), token TTL 30 min with an EXPIRED note,
one proposal per (signature, incident), one tier-3 note per incident, proposals WITHDRAWN
when the alerts resolve first.

---

## [BUG] B7 — Tier 2 can propose a rollback of a rollback

If the pipeline's Verify already rolled a bad build back, the annotations show a deploy 3
minutes ago *and* a rollback 30 seconds ago, and the alert is still firing for errors that
happened before the rollback (Eval 3's lesson). The PDF's `deploy_within_min: 30` matches and
proposes `rollout undo` — which would undo the undo and redeploy the bad build. **Substitute:**
the newest change wins: if it is a rollback, no match, tier 3 note. Tested.

---

## [BUG] B8 — "Disable Verify for the run (parameter or comment)"

There is no such parameter; commenting out a stage means committing a broken Jenkinsfile.
**Substitute:** `SKIP_VERIFY` (boolean, default false) — the Verify stage has `when {
!params.SKIP_VERIFY }`, and the Deploy stage shouts in the log when it is set. As on Day 8,
the parameter appears in the form only after one build with the new Jenkinsfile (the
remediator's first deploy does that).

---

## [DESIGN] D1 — The outcome is verified, not assumed

A tier-1 note says what *happened*: the re-run's Job condition and log tail; for a restart,
a second look 90 s later — "restart did NOT stick: … is in CrashLoopBackOff again" is the most
useful sentence a tier-1 action can write, and it is the PDF's own lesson ("restart did not
stick, this is real"), produced by the code instead of noticed by you.

## [DESIGN] D2 — Rollbacks by the remediator are annotated like rollbacks by the pipeline

The Day 10 deploy collector reads Grafana annotations; a remediator rollback that leaves none
would be invisible to the next diagnosis. `120-remediator-config.sh` mints an **Editor**
service-account token (Viewer cannot write annotations; admin is too much) into
`secret/remediator-config`; the rollback writes `tags: [rollback, activation]` and the
change-cause annotation, exactly as the Jenkinsfile does.

## [DESIGN] D3 — DRY_RUN

`DRY_RUN=true` turns every action into "dry-run: kubectl -n payments …" in the note. The unit
tests run the real server that way against a fake bot; so can you, before the first live
drill. The checkpoint insists it is off.

## [DESIGN] D4 — The approval is a pause, not a step

`123-drill-tier2.sh` prints `python3 tools/rem.py approve <token>` and waits for *you* to
run it elsewhere. The script could approve for you in one line; it deliberately does not.
The pause is the control the tier exists for.

---

## [NOTE] N1 — Numbering

Tier-1 crash-loop = INC-0012, tier-1 settlement = INC-0013, tier-2 rollback = INC-0014 (the
PDF says 0011–0013; ours are one higher since Day 8).

## [NOTE] N2 — The Day 6 benchmark

INC-0006 never recorded a manual rollback time (its table says `_N_`); the number that
exists is the pipeline's: Verify's 120 s wait plus ~30 s of rollback, before any alert.
`docs/ops-kpis.md` compares against that honestly — the pipeline path is faster *for
deploys*; the tier-2 path covers what the pipeline cannot.

## [NOTE] N3 — In-memory state

Pending tokens, cooldowns and history live in the process. A restart forgets them (the PDF
notes this; kept). One replica, `Recreate`, on purpose.

---

## Verified as correct

- The three-tier model, and "the tier lives with the action, not the incident". Right —
  written into `docs/remediation-policy.md` before the code, as instructed.
- "The fraud outage has no signature … deciding what not to automate is half the discipline."
  Right; the test suite asserts that no signature matches `ActivationHighErrorRate` without a
  recent deploy, so nobody adds one by accident.
- "The approval is a capability token, not a chat message." Right; single-use, expiring.
- "Everything writes to the incident timeline." Right, and extended: proposed, approved,
  declined, executed, failed, skipped, withdrawn, expired, follow-up.
- "Metrics on the remediator itself … on the overview dashboard." Right;
  `remediation_actions_total{signature,mode,result}`, `remediation_pending`, a row of six panels.
- "Tier 1 restarts fix transient problems and merely mask persistent ones." The best
  sentence in the PDF; INC-0012 is its demonstration.
