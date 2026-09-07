# Day 10 — Context-Enriched Alerts and the First AI Diagnosis

Adapted from `day10contextenrichedalerts.pdf`. Changes in **[CORRECTIONS-DAY10.md](CORRECTIONS-DAY10.md)**.

> The PDF puts three network calls (up to 40 s) plus an AI call inside the webhook handler
> — the Day 9 bug with a longer fuse — and hardcodes a Splunk container IP and an
> `admin:password` header in source. Its Drill B can't run as written: the pipeline builds
> `main`, not a branch, and the amount-mix test kills the bad build at Test. All fixed; the
> log has the details. Also in this build: the four prompt rules your Day 9 evals demanded.

---

## What we're building today, and why — read this first

**The gap.** Since yesterday a ticket arrives with a summary and a stakeholder update.
But the model only knows what Alertmanager sent: alert names, labels, times. When *you*
diagnosed the fraud outage on Day 3 you did three things the bot didn't: looked at current
metrics in Prometheus, ran `stats count by app.reason` in Splunk, and checked Grafana for
a recent deploy. Every bridge starts with those three lookups. Today the bot does them
itself, at the moment the ticket opens, attaches the results to the record as `context`,
and then asks the model for a **diagnosis**: what we know, most likely cause, an
alternative, next checks, and a confidence.

The half-life of this idea, from the PDF, is right: an alert that arrives saying *"error
rate 100%, every error is `fraud_service_timeout`, no deploy in the last six hours"* is
ten minutes of triage already done, at 3 AM, before anyone sits up.

**The three collectors,** each safe to fail — that rule is absolute, and the tests enforce it:

| Collector | Source | Answers | Credential |
|---|---|---|---|
| `metrics_snapshot` | Prometheus, in-cluster DNS | how bad, right now: error rate, p95, req/s, health, burn | none (cluster network) |
| `recent_deploys` | Grafana annotations API | **what changed?** — deploys *and rollbacks* of this service, with age in minutes before the first alert | a **service-account token** (Viewer), minted by the script — never the admin password in code |
| `top_log_reasons` | Splunk REST API, port **8089** | *why* — top `app.reason` values for this service's errors | the **admin login**, not the HEC token. Different port, different credential. |

Splunk is a plain container outside the cluster whose IP moves on every restart (Day 3);
the script renders the address into a Secret and `up.sh` warns when it drifts.

**The diagnosis** is a fourth prompt, with two design rules doing the work. *"Diagnosis
only. Do not propose remediation."* — the line between "AI suggests what's wrong" and "AI
changes production" is the central safety boundary of AI operations; you cross it
deliberately, with controls, on a later day, not by accident in a prompt. And *forced
structure with a confidence field* — a hypothesis with named evidence and a stated
confidence can be trusted proportionally; "it's probably the database" cannot. The prompt
also gets the deploy ages explicitly: 0–30 minutes before the alert weighs heavily; hours
old, or *after* the alert (a rollback), is not a cause.

**The experiment.** Two incidents with the *same alert name* and different true causes:
Drill A is the fraud dependency; Drill B is a bad deploy through the pipeline with Verify's
rollback as the safety net. If enrichment works, the same alert produces two different,
correct diagnoses. That contrast is the whole argument for context-enriched alerts, and it
is the story to tell in your first week on the job.

**What you're measuring.** `docs/ops-kpis.md` starts today: time to detect and time to
diagnose for every incident, backfilled. Detection has been ~2 minutes since Day 3.
Diagnosis is what Days 9 and 10 attack, and a column that got smaller is the only honest
way to say "the AI helped".

---

## Before you start

`./scripts/up.sh` green, #2/#6/#3 running, Splunk up (`docker ps | grep splunk`), an
activation incident *not* currently open (`python3 tools/inc.py list open`).

```bash
cd ~ && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day10.zip').extractall('/tmp/day10')"
cp -r /tmp/day10/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/tools/*.py ~/bhn-sim/ci/*.py
cd ~/bhn-sim && git status --short | head
```

Budget: ~2 hours. Two drills of ~10 minutes each, the rest is reading and grading.

---

## Part A — Ship the bot that looks things up

**Step 1 — Read `services/incident-bot/enrich.py`** (the three collectors and the
`_timed` wrapper that makes failure a return value) and the new `hypothesize` in `ai.py`.
Then the top of the `SYSTEM` prompt in `ai.py`: the four rules from your Day 9 evals are
there. Eval 3 measures whether they worked.

**Step 2 — Commit and ship 0.3:**

```bash
git add -A && git commit -m "Day 10: context enrichment + AI diagnosis (incident-bot 0.3), Day 9 prompt fixes"
```

Jenkins → `SERVICE=incident-bot`, `CHANGE_CAUSE=incident-bot 0.3: enrichment + diagnosis (Day 10)`.
The Test stage runs seven tests now, including three that prove the collectors degrade
in milliseconds when a source is missing.

**Step 3 — Credentials, the right way:**

```bash
./scripts/100-enrich-config.sh
```

Creates a Grafana service account (`incident-bot`, Viewer) and mints a token through the
API; proves the Splunk admin login against port 8089; stores both in `secret/enrich-config`;
restarts the bot; then asks the bot what its collectors see *right now* — all three should
say `ok` with a latency. If one doesn't, the error is printed; fix it or carry on — a
degraded collector is part of today's test, and the diagnosis will say so.

---

## Part B — The A/B drills

**Step 4 — Drill A, dependency outage:**

```bash
./scripts/102-drill-a.sh
```

Fault → ticket → within a minute: the context block (metrics, deploys, reasons) and the
hypothesis printed. Grade it *while the outage is live*: is the cause right? Is the
confidence honest? Do the suggested checks look like what you ran on Day 3? Recovers,
waits for close, writes `incidents/INC-0009-diagnosis.md`.

**Step 5 — Drill B, bad deploy:**

```bash
./scripts/103-drill-b.sh apply
```

Disables the amount-mix test *with a marker that names the drill*, inserts the velocity
check, commits (`DO NOT KEEP` in the message), then waits. You run the pipeline:
`SERVICE=activation`, `CHANGE_CAUSE=add velocity check for fraud team (Day 10 drill B)`,
`ERROR_THRESHOLD=10`. Deploy → 67% errors → ticket at ~3 min → context shows the deploy
*minutes* before the alert and `velocity_check_blocked` on top → hypothesis names the
deploy → Verify rolls back (you'll see the rollback in the context too, with a *negative*
age). Writes `incidents/INC-0010-diagnosis.md`. Then, immediately:

```bash
./scripts/103-drill-b.sh revert
```

Restores the test, removes the bug, commits, proves the gate is back. Run a clean build:
`CHANGE_CAUSE=revert drill B (Day 10)`.

**Step 6 — Grade both, side by side.** `docs/ai-eval.md` → **Eval 3**. Two questions kept
apart: did the four prompt rules work (the *drafts*), and did the same alert produce two
correct diagnoses (the *hypotheses*)?

**Step 7 — Degradation, on purpose.** Stop Splunk, post a synthetic incident, look:

```bash
docker stop splunk
python3 tools/inc.py webhook firing && sleep 20 && python3 tools/inc.py list open
python3 tools/inc.py context <id>      # log reasons: "log lookup unavailable: …" — metrics and deploys fine
python3 tools/inc.py hypothesis <id>   # should name the missing collector and lower confidence
python3 tools/inc.py webhook resolved && python3 tools/inc.py delete <id>
docker start splunk
```

---

## Part C — Measure it

**Step 8 — The KPI table.**

```bash
python3 tools/kpis.py
```

Paste the rows into `docs/ops-kpis.md`, then fill the two columns the script can't: time
to diagnose by a *human* (from your INC notes, Days 3–9) and by the *bot* (TTT + TTH, only
where Eval 3 says the hypothesis was right). Write the three sentences at the bottom.

**Step 9 — Write up INC-0009 and INC-0010** from the diagnosis files.

---

## Wrap

```bash
git add -A && git commit -m "Day 10: enriched drills A/B, Eval 3, ops KPIs"
./scripts/108-checkpoint-day10.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `100` says Splunk REST HTTP 401 | admin password — `SPLUNK_PASSWORD=… ./scripts/100-enrich-config.sh` (the Day 3 one, not the HEC token) |
| `100` can't mint a Grafana token | Grafana pod restarted mid-call; re-run. Or check `kubectl logs -n monitoring deploy/kps-grafana -c grafana` |
| metrics collector "error" | the Prometheus service name — `kubectl get svc -n monitoring` vs `PROM_URL` in the manifest |
| deploys collector HTTP 401/403 | token revoked or the SA lost Viewer; re-run `100` |
| context shows deploys from other services | shouldn't — the query is tag-filtered by service. `tools/inc.py enrich-test activation` to see the raw call |
| Drill B: no ticket after 12 min | did the build reach Deploy? If Test failed, the marker isn't on the test — `python3 ci/amount_test_gate.py status` |
| hypothesis blames the rollback | the prompt says negative ages aren't causes; if it does anyway, that's an Eval 3 ❌ worth logging |
| `up.sh` warns Splunk IP drifted | `./scripts/100-enrich-config.sh` — re-renders the address |

---

## What's next

Day 11 gives the diagnostic loop a steering wheel: an operational copilot — a small chat
tool where you ask questions in plain language and the AI answers by actually querying
Prometheus, Splunk and Kubernetes through tool calls, instead of you translating every
question into three query languages.
