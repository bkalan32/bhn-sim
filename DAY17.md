# Day 17 — New Relic, and the Knowledge Base

Adapted from `day17newrelicknowledgebase.pdf`. Changes in **[CORRECTIONS-DAY17.md](CORRECTIONS-DAY17.md)**.

> Both halves run on kind; no AWS spend. The PDF's New Relic half is "run the guided-install
> command the UI generates" — which puts your license key in a shell line and floats the
> chart version, on the platform layer Terraform has owned since Day 13. Here it is a pinned
> release with a values file, the key in a Secret, log forwarding restricted to the payments
> namespace, and the proof that data is landing comes from *Prometheus's own remote-write
> counters*, not from refreshing a UI. The knowledge base half is the PDF's design, built:
> seven entries from your own incidents, one parser and scorer shared by the bot and the
> copilot, tested in the pipeline, shipped to the bot as a ConfigMap. The drill is
> **INC-0019** (the PDF says 0018; that was yesterday).

---

## What we're building today, and why — read this first

**Part A — a hosted platform, honestly.** Every company you will work for runs one
(New Relic, Datadog, …) alongside or instead of what you built. Wiring the same cluster and
the same business metrics into New Relic is cheap; the point is the judgment at the end:
what is faster hosted, what you lose, when both. You arrive at the argument teams have
constantly with evidence instead of a preference. Two operational facts matter more than
the UI: hosted platforms **bill by ingest** (so `lowDataMode`, a log path restricted to
`payments`, and a remote-write keep-list are the controls, not decoration), and agents that
carry a **license key** must get it from a Secret, never a command line.

**Part B — the most valuable thing in the repo is not code.** Eighteen incidents in, it is
what you learned: which symptoms map to which causes, which checks tell look-alikes apart,
which fixes worked, at what tier. Today that becomes seven files in a strict shape
(`kb/`), a twenty-line search the bot and the copilot both call, and one instruction in
each prompt: *before concluding, check the team's memory and cite it.* Then the same fraud
drill for the fourth time, and the hypothesis should read differently — "matches kb-001,
seen in INC-0001/0008/0009/0018; the context confirms two of its checks; fix is external,
tier 3" — same model, same fault, better answer, because you gave it your history. That is
the whole thesis of "engineering knowledge systems" on the job description, on your own
incidents.

**The rule that keeps it alive:** every incident review updates a KB entry or says why
not. It goes in the README today.

Budget: ~3.5 h (Part A ~1.5 incl. 20 min of New Relic UI; Part B ~2). Cost: $0 (New Relic
free tier, 100 GB/month; today ships megabytes).

---

## Before you start

`docs/morning.md` (no cloud step today beyond `155` — expect all green after `152 destroy`).
Then today's files:

```bash
cd ~ && rm -rf /tmp/day17 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day17.zip').extractall('/tmp/day17')"
cp -r /tmp/day17/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh && cd ~/bhn-sim && git status --short
```

Load generators on (terminals 2/3) — Part A's drill and Part B's drill both need traffic.

## Part A · Step 1–2 — New Relic, as code (terminal 1)

You need the account from Day 1 (one.newrelic.com, free tier) and its **INGEST - LICENSE**
key: your name (bottom left) → API keys → the key of type *INGEST - LICENSE*. Not a USER key.

```bash
./scripts/171-newrelic-up.sh
```

In order: the `newrelic` namespace (Terraform, targeted), the key into Secrets via `170`
(prompted once, not echoed; two copies — the agents' namespace and `monitoring` for
Prometheus), the chart version pinned in `chart-versions.auto.tfvars`, `terraform plan`
(kps **updated in place** — the remote-write overlay — and `newrelic` created; if it says
*replace*, stop), apply, then the proofs: agent pods Running, and **Prometheus's counters**
`prometheus_remote_storage_samples_total` climbing — samples New Relic has
accepted, from the sender's point of view. The keep-list (`k8s/kps-values-newrelic.yaml`)
sends the five services' metrics, the health scores and SLO rules, and `up`; the script
prints how many series that is against how many Prometheus holds.

Then New Relic's UI: **Kubernetes** → cluster `bhn-sim` (your cluster, their opinion of
it), and **Query your data** with the NRQL the script prints — your own
`activation_requests_total`, the health scores, and the payments logs.

## Part A · Step 3 — Rebuild one thing, judge both (New Relic UI, ~20 min)

Dashboards → Create: three panels with NRQL — activation request rate, error %, p95 (the
metric names are yours; `histogram_quantile` becomes `percentile(…)` on the `_bucket`
series or the `activation_latency_seconds` summary — try both, note which works).
Alerts → Alert conditions → NRQL: activation error rate above 10 % for 2 minutes; a
notification channel to your email. Then a short drill:

```bash
./scripts/102-drill-a.sh 60
```

Watch it land in both: Alertmanager → the bot (a ticket in ~2.5 min) and New Relic → your
inbox. Note the timestamps. Then `docs/newrelic-notes.md`: the **ten lines** — faster
hosted, what you lose, what only self-run has, when both — and the evidence table at the
bottom (the NR alert time goes in there; the checkpoint looks for it). Ten honest lines
beat a page of hedging.

## Part B · Step 5 — The knowledge base (`kb/`)

Seven entries are written, in the template `kb/README.md` defines, each sourced from the
incident write-ups it cites — fraud outage, bad release, email partner, settlement crash,
settlement zero-records, crashloop, untracked drift. **Read them**; they are your
incidents in a shape a program can use. Then:

```bash
./scripts/172-kb.sh --search "ActivationHighErrorRate fraud_service_timeout"
./scripts/172-kb.sh --search "SettlementZeroRecords refusing to report success"
./scripts/172-kb.sh --search "IncidentBotDown"        # no match — the honest answer
```

The scorer is deliberately dumb — term overlap, with alert names and `app.reason` values
weighted, negated mentions ("not fraud_service_timeout") ignored — and it ranks the right
entry first on every pattern with the runner-up being the documented look-alike. That is
the prompt's job: the pattern *and* the thing to rule out.

## Part B · Step 6 — Ship it to the bot and the copilot

The bot's build changed (`kb.py`, `ai.py`'s prompt, `app.py`'s `/ai` and `/kb/search`,
a `/kb` mount in the manifest, `tests/test_kb.py`). It goes through the pipeline like
every service change:

```bash
git add -A && git commit -m "Day 17: knowledge base — kb/*.md, kb.py shared by bot + copilot, tests; New Relic as code"
```

Jenkins → **deploy-service** → `SERVICE=incident-bot`, change cause `Day 17: knowledge base
in the hypothesis prompt` → Build. The test stage runs `test_kb.py` (a malformed KB file
fails the build before it ships); Verify holds 30 s. Then:

```bash
./scripts/172-kb.sh                 # validate, ConfigMap kb, restart the bot, /ai shows the entries
python3 tools/copilot.py -q "activation errors are up and the logs say fraud_service_timeout — is this a known pattern?"
```

The copilot's answer should name `kb-001`, the incidents it came from, and run one of
its discriminating checks with `query_prometheus` or `search_logs` before concluding.

## Part B · Step 7 — Prove the difference

```bash
./scripts/173-kb-drill.sh
```

Before injecting, it shows what the bot will match for the fault's words. After the ticket:
the KB entries the bot actually put in the prompt (`ai_meta.hypothesis.kb_matches` — so a
grader can tell "cited" from "was never offered"), then the hypothesis. Section 6 should
say **matches kb-001**, which checks the context already confirms (the reason histogram,
no deploy), which remain, and the team's prior answer (external, tier 3). Write
`incidents/INC-0019.md` (template shipped), row 0019 in `docs/ops-kpis.md`, and **Eval 8**
in `docs/ai-eval.md`: INC-0009 (no KB) vs INC-0018 (no KB, no logs) vs INC-0019 (KB) —
same model, same fault.

---

## Wrap

```bash
git add -A && git commit -m "Day 17: New Relic wired and judged; KB cited by bot and copilot (INC-0019); maintenance rule"
./scripts/178-checkpoint-day17.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `170`: key is not 40 chars / does not end NRAL | that is a USER key (NRAK-…) or a browser key — the *INGEST - LICENSE* type |
| `170`: Metric API HTTP 403 | wrong key type or another account's key |
| `171`: plan wants to *replace* kps | stop — an overlay change is in-place; `./infra/local/tf.sh plan` and read it; Day 13's "inconsistent result" class → `untaint` |
| agent pods CrashLoopBackOff | `kubectl -n newrelic logs <pod> \| grep -i licen` — the Secret name/key must match `customSecretName`/`customSecretLicenseKey` exactly |
| `171 --status`: succeeded 0, failed climbing | the remote-write key: `kubectl -n monitoring get secret newrelic-license`; Prometheus log `grep -i remote`; 401 = wrong key, 413/429 = the keep-list is missing |
| New Relic shows the cluster but no `activation_*` | remote write not succeeding (above), or you are looking at Infrastructure instead of *Query your data* / Metrics |
| `172`: `FAIL kb-00x: …` | the parser is the contract: `key: value`, `[a, b]`, `- item` only; `tier` is 1/2/3; `learned_from` names real `incidents/INC-*.md` |
| `172`: "the bot does not see the KB" | the running image predates Day 17 — Jenkins deploy-service SERVICE=incident-bot, then `172` again |
| `173`: hypothesis does not cite kb-001 | was it offered? (`kb_matches` line) — if offered and ignored, that is a finding for Eval 8; if not offered, `172 --search` with the ticket's words |
| Jenkins test stage fails on `test_kb.py` | it is doing its job: the message names the file and the field |
| the copilot never calls `search_kb` | it is a "why" question? Ask one ("what is causing…"); `--selftest` proves the tool itself works |

---

## What's next

Day 18: alert hygiene — every alert audited against fatigue principles — the operational
KPI set, and an AI-generated daily ops report so the platform briefs you instead of the
reverse. Carry-over: the CloudWatch collector for the bot (INC-0018's follow-up), and the
KB entry each of tomorrow's findings will want.
