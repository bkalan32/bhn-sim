# Day 9 — Corrections Log

Source: `day9aiincidentsummaries.pdf` · Verified 7 September 2026 against the running lab.

---

## [BUG] B1 — The AI call runs inside the webhook handler, and the handler is `async def`

**Guide, Step 2:** `inc["ai_open_draft"] = ai.summarize_open(inc)` "on creation", inside
`async def receive(request)`.

Two failures stacked. First, an LLM call takes 5–60 seconds; Alertmanager's webhook
delivery has a timeout and **retries on failure with backoff** — a slow bot gets the same
webhook again, and the PDF's bot would append a second `alerts_firing` event (and, with its
`groupKey` join, possibly open a second incident). Second, and worse: `urllib.request` is
*blocking*, and a blocking call inside an `async def` FastAPI handler stops the **entire
event loop** until it returns. For up to 60 seconds nothing else is served — including
`/healthz` and `/readyz`. Kubernetes fails the liveness probe and restarts the pod
mid-draft. The AI didn't just slow the ticketing system; it killed it.

**Substitute:** the webhook handler saves the record and returns in milliseconds; a
background thread drafts and attaches. `ai_draft_attached` becomes a timeline event with
the model and latency. The PDF's "most important line of AI engineering" — the try/except —
is still there (`ai._call` never raises), but it was protecting against the wrong failure.

---

## [BUG] B2 — `envFrom: secretRef` without `optional: true` makes the key mandatory

**Guide, Step 2 + "Day 9 is done when":** mount `ai-keys` via `secretRef`, then "delete
the env, fire a drill, confirm the incident still records."

With a required `secretRef`, a pod whose secret is missing does not *start*
(`CreateContainerConfigError`). The bot cannot record anything because there is no bot.
The PDF's own resilience test fails at the Kubernetes layer before the try/except gets a
say. `optional: true` on the reference, and `AI_PROVIDER=none` as the switch
(`93-ai-resilience.sh`) so you can prove the no-AI path without deleting and retyping the
key.

---

## [BUG] B3 — The Ollama fallback is "adapt `_call` (10 lines)"

Provided instead: a provider switch (`anthropic | ollama | fake | none | auto`). `fake`
matters more than it looks — it is how the bot's unit tests exercise the full
background-draft path with no network and no key, so the pipeline's Test stage can run
them. `90-ai-secret.sh --ollama URL` configures the local path. Caveat from inside kind:
pods reach the Windows host through `host.docker.internal` on Docker Desktop, usually; if
not, the host's LAN IP with `OLLAMA_HOST=0.0.0.0`.

---

## [BUG] B4 — The model name is hoped, not checked

**Guide, Step 1:** `MODEL = os.getenv("AI_MODEL", "claude-sonnet-4-5")`. Model IDs change;
a wrong one is an HTTP 404 that the PDF's bot swallows into "(AI draft unavailable: …)" on
every incident, quietly, forever. `90-ai-secret.sh` calls `/v1/models` (proves the key,
lists what the account can use) and sends a 5-token message to the configured model
before storing anything. A 404 at setup is a two-minute fix; a 404 on the first real
incident is an outage of the assistant during the outage.

---

## [BUG] B5 — Feeding `time.time()` floats to a language model

The PDF's record is `"opened_at": 1788556435.68` all the way down, and then asks the model
for "when it started" and "duration". Day 8's bot already writes ISO strings next to every
epoch. Day 9 adds **the current time to the prompt**, so "how long ago" is computable, and
drops the bot's own earlier drafts from the record before prompting, so a re-draft cannot
cite a previous draft as evidence. Also `temperature: 0.2` — you cannot grade output that
changes wildly between identical runs — and `max_tokens: 1500`, because the resolved draft
is three sections plus a six-heading skeleton and 1000 truncates it mid-heading.

---

## [BUG] B6 — `helm`-free but not free: settlement's failure erased its own last success

Not in the PDF; found on Day 8. `push_to_gateway` is HTTP **PUT** — it replaces every
metric in the Pushgateway group. A failed settlement run never set
`settlement_last_success_timestamp`, pushed the gauge's default **0**, and the overview
read "56.7 years since last success" while `SettlementStale` fired instantly. The failure
overwrote the memory of the success. `settlement:0.3`: two registries, `pushadd_to_gateway`
(HTTP **POST**, replaces only same-named metrics), and the success timestamp is pushed only
when one was actually recorded — which also covers the lenient path's exit-0-on-zero.
Verified locally against a fake gateway: crash/silent/lenient push no timestamp; `none`
does.

---

## [DESIGN] D1 — Re-draft on demand, and the bare/annotated comparison from one drill

**Guide, Step 5:** run a second drill with notes and compare the skeletons. Ours adds
`POST /incidents/{id}/draft?kind=…` — regenerate a draft on any record, including the Day 8
incident written before the AI existed. So Eval 1 (no notes) comes from the Day 8 record
without another 10-minute outage, and Eval 2 comes from today's drill with notes. Same
model, same prompt, one variable: what a human put on the record. The endpoint is also how
you re-run after a prompt change — that is the "before/after evidence" the PDF wants
`docs/ai-eval.md` to carry.

---

## [DESIGN] D2 — Metrics for the AI layer

`ai_drafts_total{kind, outcome=ok|error|disabled}` and `ai_draft_latency_seconds`. Monitor
the monitor's assistant: a quiet stream of `outcome="error"` is the 404-forever failure
from B4, visible on a panel instead of discovered during an incident.

---

## [NOTE] N1 — Numbering

The PDF logs this day's drill as INC-0007. Ours is **INC-0008**, because INC-0007 was the
Day 8 drill that the PDF did not write up. Day 10's A/B drills become INC-0009 and
INC-0010.

---

## Verified as correct

- "The AI drafts, a human decides." The whole day's principle; right, and repeated in
  every script's closing lines on purpose.
- Key in a Kubernetes Secret, never in code or committed YAML. Right — and `read -s` so it
  is not in your shell history either.
- The four prompt-design points (scope constraint, two audiences, business context in
  the system prompt, 'not yet known' as an allowed answer). All right; the system prompt
  here keeps them and adds "timestamps are UTC, quote them as given".
- Grading drafts against the record, claim by claim, into `docs/ai-eval.md`. Right, and
  the rubric there makes "invented" a hard fail regardless of fluency.
- "The model can only be as good as the record, so improve the record." The best line in
  the PDF and the reason Day 8's bot has notes and ISO timestamps.
