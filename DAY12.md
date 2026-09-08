# Day 12 — Auto-Remediation, With the Safety On

Adapted from `day12autoremediation.pdf`. Changes in **[CORRECTIONS-DAY12.md](CORRECTIONS-DAY12.md)**.

> The PDF's remediator deletes "the first pod with more than 3 restarts" through a shell
> pipeline, runs rollbacks inside the webhook handler, writes its notes on whichever ticket
> is open first, and says "do not skip the RBAC" without writing any. Its crash-loop
> signature can never fire (no `service` label, `for: 15m`), and its tier-2 drill has no way
> to disable Verify. All fixed; the log has the details.

---

## What we're building today, and why — read this first

**The line.** Detection is automated (alerts), record-keeping is automated (bot), context
and diagnosis are automated (enrichment, hypothesis, copilot). The one thing every day so
far has refused to automate is the *fix*. Today crosses that line — deliberately, with
controls — because "self-healing systems" is in the job description and because an
automation that restarts the wrong thing during an incident is a second incident.

**The policy comes first.** `docs/remediation-policy.md` is written before the code, and
it is the authority. Three tiers, and *the tier lives with the action, not the incident*:

| Tier | Runs when | Today |
|---|---|---|
| **1 · auto** — safe, reversible, well understood; runs now, notifies after | the signature matches | delete a crash-looping pod; re-run a failed settlement job |
| **2 · approve** — right action known, but blast radius; *prepared* automatically, *executed on one human yes* (a capability token) | the signature matches | roll back activation after a deploy within 30 min |
| **3 · human** — novel, destructive, or a fix the platform cannot take; automation only assembles context | nothing matches | the fraud outage: "human required" on the ticket, nothing else |

Note what has no signature: the fraud dependency outage. Its fix is outside the platform.
The tests assert nobody adds one by accident. **Deciding what not to automate is half the
discipline.** And promotion between tiers is *earned* — five clean runs under approval and
a line in the policy — never assumed.

**The remediator** is a fourth small service on the same Alertmanager fan-out as the bot.
For each firing group it looks for a signature; tier 1 runs in a background thread and
writes the outcome — *the outcome, not the attempt*: a re-run that crashed is a FAILED note,
a restart after which the pod loops again is "restart did NOT stick — this is real"; tier 2
posts a proposal with rationale, evidence and a single-use token that expires; no match
writes one "human required" note. Cooldown per signature, one bounded retry, proposals
withdrawn if the alerts clear first. Everything on the incident timeline, prefixed
`[remediator]`, so "what has the automation already done?" has an instant answer.

**The safety is RBAC, not the code.** The remediator's ServiceAccount has a Role that maps
verb-for-verb to the three actions: delete pods, create jobs, patch **one** deployment
(`activation`), in **one** namespace. It cannot read a secret, delete a Deployment, or touch
egift. `kubectl auth can-i --as=system:serviceaccount:payments:remediator` asks the API
server, not our belief, and the checkpoint runs fourteen of those questions.

**What you measure.** Alert → recovered for the tier-2 path, next to the pipeline's Verify
number from Day 6 — and the honest comparison in `docs/ops-kpis.md`: the pipeline is faster
*for deploys* because it does not wait for an alert; the tier-2 path covers what the
pipeline cannot, and turns "find the cause, decide, type" into "decide".

---

## Before you start

`./scripts/up.sh` green; Day 11 checkpoint 11/11; both generators and Grafana up; no open
incidents (`python3 tools/inc.py list open`).

```bash
cd ~ && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day12.zip').extractall('/tmp/day12')"
cp -r /tmp/day12/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/tools/*.py
cd ~/bhn-sim && git status --short
```

Budget: ~2.5 hours. Three drills (≈8, ≈10, ≈12 minutes) plus the shipping and the reading.

---

## Part A — Policy, then the service

**Step 1 — Read `docs/remediation-policy.md`.** Then `services/remediator/signatures.py`
(the executable half of the policy) and the Role in `k8s/remediator.yaml` — every verb is
one line of `app.py`. Then `app.py`'s `_tier1`, `_tier2_propose` and `_approve`.

**Step 2 — Test, commit, ship `remediator:0.1`:**

```bash
cd services/remediator && python3 -m venv .venv && . .venv/bin/activate && pip install -q -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests/ && deactivate && cd ~/bhn-sim
./scripts/09-grafana-dashboards.sh
git add -A && git commit -m "Day 12: remediator 0.1 (three tiers, scoped RBAC), policy, drills"
```

Eight tests, all with `DRY_RUN=true` against a fake bot: the right ticket gets the note, the
cooldown skips and says so, the fraud outage gets exactly one tier-3 note, propose → approve
→ single-use token → RECOVERED, and "newest change is a rollback" is not a match.

Jenkins → `SERVICE=remediator`, `CHANGE_CAUSE=remediator 0.1: three tiers, scoped RBAC (Day 12)`.
The Build stage downloads kubectl into the image (pinned). Verify is the 30-seconds-and-
zero-restarts check. This build also teaches Jenkins the new `SKIP_VERIFY` parameter.

**Step 3 — Credentials and the RBAC proof:**

```bash
./scripts/120-remediator-config.sh
```

Mints a Grafana **Editor** token (a remediator rollback must be annotated like a pipeline
rollback, or the Day 10 collector never sees it), restarts the remediator, then asks the API
server fourteen questions about what the ServiceAccount may do. All `yes` on the three
actions, all `no` on the boundary.

**Step 4 — Fan-out, rules, and an end-to-end proof:**

```bash
./scripts/121-remediator-route.sh
```

Loads `PaymentsPodCrashLooping` and `RemediatorDown`, adds the second webhook through the
Day 8 script (pinned helm upgrade, three proofs), then sends one synthetic alert through
every hop: bot opens a ticket → remediator finds it → no signature → "tier 3: human required"
on that ticket. If that note appears, the plumbing works. Cleans up after itself.

---

## Part B — Drills, one per tier

**Step 5 — Tier 1, crash-loop (INC-0012):**

```bash
./scripts/122-drill-tier1.sh crashloop
```

A throwaway Deployment whose container exits at startup → `PaymentsPodCrashLooping` (~3 min)
→ ticket → AUTO note (which pod, and the CrashLoopBackOff check it did first) → 90 s later
the follow-up: *restart did NOT stick*. The Deployment replaced the pod; the replacement
loops too; the cooldown prevents a second delete. That is the classic critique of naive
self-healing, on your own ticket. The fixture is removed at the end.

**Step 6 — Tier 1, settlement (INC-0013):**

```bash
./scripts/122-drill-tier1.sh settlement
```

Crash mode, one run → `SettlementJobFailed` → ticket → the remediator re-runs the job → it
crashes too → **FAILED** note + "retry once in 180 s". The script sets the mode back to
`none` while the clock runs; the retry succeeds; `last_success` recovers with nobody touching
kubectl. A genuine self-heal — genuine because the first attempt told the truth.

**Step 7 — Tier 2, the headline (INC-0014):**

```bash
./scripts/123-drill-tier2.sh apply
```

Same bad release as Days 6/8/10. You run the pipeline with **`SKIP_VERIFY=true`** — the only
time that box is ever ticked — so nothing rolls it back automatically. Errors → alert →
ticket → within seconds a **PROPOSED** note: evidence (the deploy, minutes before), rationale,
a token. The script prints the command and **waits for you**:

```bash
python3 tools/rem.py approve <token>      # in Terminal 2 — this is the human yes
```

`rollout undo` runs as the remediator's ServiceAccount, the change-cause and Grafana
annotation are written, the alerts clear, a **RECOVERED** note lands with the seconds, and
the script prints every interval from the record's own timestamps. Then immediately:

```bash
./scripts/123-drill-tier2.sh revert
```

and a clean build (`SKIP_VERIFY` unticked, `CHANGE_CAUSE=revert tier-2 drill (Day 12)`).

---

## Part C — Write it down

**Step 8** — `incidents/INC-0012.md`, `INC-0013.md`, `INC-0014.md` from the tickets
(`python3 tools/inc.py timeline <id>` shows every `[remediator]` note with its time).

**Step 9** — `docs/ops-kpis.md`: row 0014 and the approve-to-recover line next to the
pipeline number. `docs/remediation-policy.md`: the four "what we learned" lines. The
promotion log stays empty — one run is not five.

---

## Wrap

```bash
git add -A && git commit -m "Day 12: three remediation drills (INC-0012..0014), policy learned, KPIs"
./scripts/128-checkpoint-day12.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Jenkins build fails in Build: cannot download kubectl | the Jenkins container has no internet at that moment; retry, or `docker exec jenkins curl -I https://dl.k8s.io` |
| `120 --check`: a `yes` where `no` was expected | the Role grew; diff `k8s/remediator.yaml` against the policy table |
| `121`: no remediator note on the synthetic ticket | `kubectl logs -n payments deploy/remediator \| python3 tools/logfmt.py` — usually the bot URL or the fan-out not loaded yet |
| crash-loop drill: no ticket after 7 min | Prometheus > Rules: is `PaymentsPodCrashLooping` there? `kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}` in Explore |
| AUTO note says "refused: … not in CrashLoopBackOff" | the alert was stale by the time the remediator looked; that refusal is correct behaviour |
| settlement drill: retry also FAILED | mode was still `crash` when the retry ran — set `none` within the 180 s window |
| tier 2: no PROPOSED after the alert | `python3 tools/inc.py context <id>` — does the bot's deploy collector show the deploy? If the deploy annotation is missing, the pipeline's Grafana step failed |
| tier 2: PROPOSED but `approve` says 404 | token expired (30 min) or the remediator restarted (in-memory) — trigger nothing; roll back by hand as on Day 6 and note it |
| `approve` hangs ~60 s | normal: it waits for `rollout status` and answers with the result |
| egift ticket says "human required" during the tier-2 drill | correct — egift's errors are the cascade; no egift signature exists |

---

## What's next

Day 13 moves the ground under the platform into code: Terraform manages the cluster's
add-ons declaratively, drift becomes detectable, and "what changed?" gets an answer at the
infrastructure layer too.
