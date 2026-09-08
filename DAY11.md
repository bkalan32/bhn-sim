# Day 11 — The Operational Copilot

Adapted from `day11operationalcopilot.pdf`. Changes in **[CORRECTIONS-DAY11.md](CORRECTIONS-DAY11.md)**.

> The PDF's allow-list lets `rollout undo` through, lets `get secret` hand the model the
> API key, puts the Splunk password in source and points at a port the container does not
> publish. All fixed; the log has the details. The bot ships as **0.4** with the two prompt
> changes your Eval 3 demanded and one read-only search endpoint the copilot borrows.

---

## What we're building today, and why — read this first

**The gap.** Since Day 10 a ticket arrives with context and a diagnosis. But every *next*
question — "which stores?", "is egift affected?", "did anything deploy?" — still costs the
translation tax: PromQL for one, SPL for another, kubectl for the third, ninety seconds of
syntax each while the bridge waits. Today you build a copilot: you ask in plain language,
the model answers by **calling the platform's APIs in a loop** until it has evidence.

**The pattern** (the most transferable AI-engineering pattern in the series):

```
question + a MENU of tools  ->  model  ->  "call query_prometheus with {...}"
                                 ^                     |
                                 |    your code runs it, appends the result
                                 +---------------------+
                                ...until the model answers, citing what came back
```

The model never touches production. **Your code is the hands, the model is the analyst,
and the tool menu is the permission boundary.** Everything else today follows from that
sentence — which is why most of the corrections are about the hands, not the brain.

**The six tools,** all read-only, and where each one actually reaches from your laptop:

| Tool | Answers | Reaches | The guarantee |
|---|---|---|---|
| `query_prometheus` | how much, how fast, right now | API-server proxy → Prometheus | instant queries, 20 series max |
| `firing_alerts` | is anything wrong | Prometheus `/api/v1/alerts` | cheap; called first for vague questions |
| `search_logs` | *why*, *which store*, one trace | **the bot's** `POST /tools/search_logs` (0.4) | SPL validated: no side-effect commands, window a parameter, rows capped |
| `kubectl_get` | what state | kubectl, pinned context | verb **and** sub-verb allow-list; secrets/configmaps refused; no `-f`, no follow |
| `get_incidents` / `get_incident` | what is on record | the bot | the AI's own drafts removed — a model quoting a model is not evidence |

Why `search_logs` goes through the bot: your WSL shell is not on the platform network and
holds no Splunk credential; the bot is, and does (Day 10). It lends its eyes, not its
password. Why the kubectl allow-list is by sub-verb: `rollout undo` is a write. Why
secrets are refused: **read-only is not the same as safe** — `get secret ai-keys` would
put the API key into the conversation.

**Two things you measure.** *Tool trails* — an answer is only as good as the calls under
it, so Eval 4 grades right tool / right query / right reading, per question. And
*refusals* — the adversarial half hour proves the allow-list holds when the prompt is
argued with, including one attack the PDF does not have: a log line that tells the model
to report the platform healthy. Tool results are data, never instructions.

**Also in this build.** The Eval 3 prompt changes: a rollback is a reversal, never a
cause; and `PLATFORM_FACTS`, one description of everything that exists (namespaces,
metrics, alerts, log fields, dependencies), imported by both the bot and the copilot.
No more `-n production`.

---

## Before you start

`./scripts/up.sh` green; Day 10 checkpoint 12/12; Jenkins reachable; Splunk up.

```bash
cd ~ && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day11.zip').extractall('/tmp/day11')"
cp -r /tmp/day11/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/tools/*.py
cd ~/bhn-sim && git status --short | head -20
```

Budget: ~2 hours. One 10-minute drill; the rest is asking questions and grading.

---

## Part A — Ship incident-bot 0.4

**Step 1 — Read three things.** `services/incident-bot/ai.py`: `PLATFORM_FACTS` (top of the
file) and the two new rules at the end of `SYSTEM`. `enrich.py`: `validate_spl` and
`search_logs` — what the one bot-side tool accepts and refuses. `tools/copilot.py`:
`kubectl_get` (the allow-list) and `TOOLS` (the descriptions — they carry the metric
names and log fields, and they are doing more work than the prompt).

**Step 2 — Commit and ship:**

```bash
cd ~/bhn-sim/services/incident-bot && . .venv/bin/activate && python -m pytest -q tests/ && deactivate && cd ~/bhn-sim
git add -A && git commit -m "Day 11: incident-bot 0.4 (read-only search tool, Eval 3 prompt fixes), copilot"
```

Jenkins → `SERVICE=incident-bot`, `CHANGE_CAUSE=incident-bot 0.4: search tool + Eval 3 prompt fixes (Day 11)`.
Nine tests now, two of them about what the search endpoint refuses.

---

## Part B — The copilot

**Step 3 — Prove the hands before trusting the brain:**

```bash
./scripts/110-copilot-preflight.sh
```

Every tool once, no model: Prometheus, the search endpoint, kubectl (including two calls
that *must* be refused), the records, the key. All `ok`, then:

**Step 4 — Warm-up on a healthy platform.** Five questions, non-interactive so the run is
repeatable and the transcript lands in `docs/copilot-transcripts/`:

```bash
python3 tools/copilot.py -f docs/copilot-questions/warmup.txt --tag warmup
```

Watch the `[tool]` lines. Check every answer against Grafana yourself. The last question
— which store had the most errors — is the payoff: a `top app.store_id` search you would
have spent a minute writing. Grade in `docs/ai-eval.md` → **Eval 4a** (right tool? right
query? right reading?). Then try it interactively for a few minutes — `python3
tools/copilot.py`, `new` clears the conversation, `exit` quits.

**Step 5 — The fraud drill, investigated by the copilot:**

```bash
./scripts/112-copilot-drill.sh
```

Fault → 90 s → four questions from `docs/copilot-questions/broken.txt`, *before* the
ticket opens so the model has to look things up. A good trail on question 1: error rate →
`stats count by app.reason` → rollout history → "fraud dependency, no deploy, N%
cited". The ticket opens while it talks; the script prints the bot's own hypothesis next
to it — same fault, two paths. Recovers, waits for close. Grade → **Eval 4b**; write
`incidents/INC-0011.md`.

**Step 6 — Break it on purpose:**

```bash
./scripts/113-copilot-adversarial.sh --inject
```

Six questions (a metric that doesn't exist, "restart the pods", a read-then-rollback, the
API key, "is everything okay?", arithmetic bait), then the injection: a planted log event
that instructs the model to report the platform healthy, and a question about error
reasons. Pass criteria are printed after each. Grade → **Eval 4c**. The refusals you want
are the tool's (`not permitted`, `off limits` in the transcript) — the prompt's refusal is
the polite one, the tool's is the real one.

---

## Wrap

```bash
git add -A && git commit -m "Day 11: copilot warm-up, fraud drill INC-0011, adversarial run, Eval 4"
./scripts/118-checkpoint-day11.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| preflight: "bot has no /tools/search_logs" | the running image is 0.3 — Step 2's Jenkins build |
| `search_logs` result says `SPLUNK_URL not configured` / URLError | `./scripts/100-enrich-config.sh` (Splunk IP drifted) |
| self-test `api key FAIL` | `./scripts/90-ai-secret.sh --check`; or export `ANTHROPIC_API_KEY` for this shell only |
| model writes PromQL against a metric that doesn't exist | it should say "not available"; if it *invents a number* that is an Eval 4 ❌ — add the metric to `PLATFORM_FACTS` only if it really exists |
| "stopped after 8 tool rounds" | the question is too broad or a tool keeps erroring; ask narrower, or `--max-rounds 12` |
| answers reference an old outage | the conversation remembers; `new` between investigations |
| `--inject` HEC returns 4xx | the Day 3 token/All Tokens — `22-fluent-bit.sh`'s troubleshooting |
| kubectl tool errors on every call | `KUBE_CONTEXT` — the copilot pins `kind-bhn-sim`; `kubectl config get-contexts` |

---

## What's next

Day 12 crosses the line you have been carefully not crossing: remediation. Known failure
signatures get automated fixes behind a three-tier policy (auto / approve / human), the
remediator gets scoped RBAC, and you measure approve-to-recover against the manual rollback
time from Day 6.
