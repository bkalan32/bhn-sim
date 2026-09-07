# Day 9 — AI Incident Summaries and Communications

Adapted from `day9aiincidentsummaries.pdf`. Changes in **[CORRECTIONS-DAY9.md](CORRECTIONS-DAY9.md)**.

> The PDF calls the LLM *inside* the webhook handler, which is `async def` — a 60-second
> blocking call there freezes the whole bot, health probes included, and Kubernetes
> restarts it mid-draft. Its secret mount is mandatory, so its own "remove the key and prove
> it still works" test can't start the pod. Both fixed. Also shipped: `settlement:0.3`, the
> "a failed run erased the last-success timestamp" bug we found on Day 8.

---

## What we're building today, and why — read this first

**The gap.** Since yesterday, incidents open and close themselves with a full timeline.
Nobody wants to read them: they're JSON. During a real major incident a surprising share
of the bridge's time goes into *writing* — the status update every 30 minutes, the
executive summary, the post-incident review. The job description names exactly this:
"AI-powered incident summaries" and "AI-assisted incident communications."

**The principle, stated once and enforced everywhere:** *the AI drafts; a human decides.*
An LLM writing a stakeholder update is leverage. An LLM declaring an incident resolved, or
running a fix, is a new incident. Nothing you build today changes production. It writes
text onto a record, and a person reads it.

**The mechanism.** Two moments in an incident's life get a draft:

| Moment | Draft | Audience |
|---|---|---|
| ticket opens | internal summary (what's firing, which flow, since when, what to check first) + stakeholder update (what customers see, what we're doing, next update in 30 min) | engineers joining; leadership |
| ticket resolves | resolution note + stakeholder close-out + post-incident review skeleton with six headings filled where the record allows and *'not yet known'* where it doesn't | everyone; the review meeting |

The model is told, in a system prompt, what it may use (*the record only*), what it may
not do (*invent metrics, causes or times*), and what the business is (*activation errors
mean cards declined at tills*). That last part is how a model knows a 100% activation
error rate matters. In the real job, feeding your company's context into these systems is
most of the work.

**Where the call runs, and why it matters.** An LLM call takes 5–60 seconds. The bot
receives webhooks in milliseconds and must keep doing so — Alertmanager retries slow
deliveries, and a blocking call inside an async handler stops *everything*, including the
health probes Kubernetes uses to decide whether to restart the pod. So the draft runs in a
background thread and attaches when it's done, as a timeline event with the model and
latency. The ticket exists before the AI is consulted, and it exists whether or not the AI
answers.

**What makes drafts better: the record, not the prompt.** The model can only use what's
on the record. Today you also play the bridge scribe: during the drill you post what you
observe and what you do as *notes*. Then the resolution draft's *Root cause* and *Timeline*
come from your notes — cited, not invented. Same model, same prompt; the only variable is
what a human put on the record. That comparison is the lesson, and `docs/ai-eval.md` is
where you grade it, claim by claim.

**Cost.** A draft costs a fraction of a cent; the day costs less than a coffee. The key
lives in a Kubernetes Secret and nowhere else.

---

## Before you start

`./scripts/up.sh` green, load generators (#2, #6) and Grafana (#3) running. An Anthropic
API key from https://console.anthropic.com → API keys (add $5 of credit). No Ollama
needed unless you want the offline path.

```bash
cd ~/bhn-sim
cp -r /mnt/c/Users/bkala/Downloads/bhn-sim/. ~/bhn-sim/
git status              # Day 9 files: ai.py, scripts/9*, docs/ai-eval.md, settlement 0.3 ...
```

Budget: ~90 minutes, of which ~12 is the drill and ~20 is grading.

---

## Part A — The key, and proof it works

**Step 1 — Read `services/incident-bot/ai.py`.** Eighty lines that matter: the system
prompt (the guardrails), the provider switch, `_call` that *never raises*, and the two
prompts. Note what the record excludes before it goes to the model: its own earlier drafts.

**Step 2 — Store the key.**

```bash
./scripts/90-ai-secret.sh
```

It asks for the key without echoing it, checks it against `/v1/models` (and lists the
models your account can use), sends a five-token test message to the configured model
(a wrong model name is a 404 *now*, not on your first real incident), stores it as
`secret/ai-keys`, restarts the bot, and shows what the bot sees: `provider: anthropic`.

Never paste the key anywhere else. `--check` re-verifies later; `--remove` takes it away.

---

## Part B — Ship the bot that drafts

**Step 3 — Read the diff in `app.py`.** Search for `_schedule_draft`. The webhook handler
returns first; the thread drafts after. Then `k8s/incident-bot.yaml`: `optional: true` on
the secret, and why.

**Step 4 — Commit and ship both changed services.**

```bash
git add -A && git commit -m "Day 9: AI drafts in the incident bot (0.2), settlement 0.3 keeps last_success on failure"
```

Jenkins → Build with Parameters:
1. `SERVICE=incident-bot`, `CHANGE_CAUSE=incident-bot 0.2: AI drafts (Day 9)` — the Test stage runs the bot's tests with the *fake* provider (no network, no key); Verify checks it stays up.
2. `SERVICE=settlement`, `CHANGE_CAUSE=settlement 0.3: failed run must not erase last_success` — Verify runs a job. Then `./scripts/44-settlement-failure.sh crash` followed by `none`: the "minutes since last success" panel should **not** jump to 56.7 years this time.

(No Jenkins? `./scripts/80-build-incident-bot.sh` now builds whatever version the manifest declares; `./scripts/83-settlement-strict.sh --local` for settlement.)

**Step 5 — One-minute proof.**

```bash
./scripts/91-ai-smoke.sh
```

Synthetic incident → open draft attaches in the background → resolved → resolution draft →
both printed with model, latency and token counts → record deleted. Read the drafts as an
engineer: the record had one alert called `SmokeTest` with a one-line summary. Did the
model stay inside that?

---

## Part C — The drill, with you as the scribe

**Step 6 — Eval 1, from the Day 8 record (no notes, no new outage).**

```bash
python3 tools/inc.py list                        # find the Day 8 activation incident
python3 tools/inc.py draft <id> open
python3 tools/inc.py draft <id> resolved
```

Grade them into `docs/ai-eval.md` → **Eval 1**. The Root cause heading should read
*not yet known*: the record has alerts and times, no cause. If it names one, that's a ❌.

**Step 7 — Eval 2, live.**

```bash
./scripts/92-ai-drill.sh
```

Fraud outage → ticket → **open draft printed** (read it against `tools/inc.py timeline`)
→ you post note 1 (what Splunk shows; your own words beat the canned line) → hold →
recover → note 2 → resolve → **resolution draft printed** → everything written to
`incidents/INC-0008-ai-drafts.md` with the timeline as ground truth.

Root cause and Timeline should now be filled — from *your* notes, cited as such. Grade into
**Eval 2**, fill the comparison table, and answer the one-sentence question at the bottom.

**Step 8 — Prove it works without the AI.**

```bash
./scripts/93-ai-resilience.sh
```

Provider off → synthetic incident opens and resolves with a full record → drafts say *why*
they're missing → provider back on. The incident system must never fail because the AI
failed.

**Step 9 — Write up INC-0008** from the drafts file; the scaffold has the timing table.

---

## Wrap

```bash
git add -A && git commit -m "Day 9: INC-0008, AI eval 1+2, resilience proven"
./scripts/98-checkpoint-day9.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `90` says HTTP 401 | wrong/revoked key; nothing was stored |
| `90` says model not found (404) | pick an id from the list it printed: `AI_MODEL=<id> ./scripts/90-ai-secret.sh` |
| drafts say `(AI draft unavailable: URLError …)` | the pod has no egress. `kubectl exec -n payments deploy/incident-bot -- python3 -c "import urllib.request;print(urllib.request.urlopen('https://api.anthropic.com',timeout=10).status)"` |
| drafts say HTTP 429 / 529 | rate-limited / overloaded; `tools/inc.py draft <id> open` retries on demand |
| no draft after 90s, no error | `kubectl logs -n payments deploy/incident-bot \| python3 tools/logfmt.py` — look for `ai draft attached` with `ok=false` |
| drafts contain invented details | tighten `SYSTEM` in `ai.py`, lower `max_tokens`, log it in `docs/ai-eval.md` "Failures worth keeping", rebuild — that log is the deliverable |
| Jenkins Test stage fails for incident-bot | run `cd services/incident-bot && . .venv/bin/activate && python -m pytest -q tests/` locally; the tests use the fake provider, no key needed |

---

## What's next

Day 10 closes the loop from the other side: at the moment a ticket opens, the bot fetches
current metrics from Prometheus, recent deploys from Grafana and top error reasons from
Splunk, attaches them to the record, and asks the model for a *diagnosis* — hypothesis,
alternative, next checks, confidence. Diagnosis only; never remediation.
