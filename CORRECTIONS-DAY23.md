# Day 23 — Corrections Log

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 23 · built 24 Sep 2026 on the lab
Day 22 left (mission-control:56, INC-0023 committed). Verified that day against the current
Anthropic docs: the Messages API (adaptive thinking, `display: "summarized"`, strict tools,
server-side fallback beta `server-side-fallback-2026-07-01`), model prices, the MCP Python SDK
2.2 (`MCPServer`, streamable HTTP), and Claude Code's MCP config (`headersHelper`). The MCP path
was tested end to end with a real Claude Code (2.1.281) against the render harness before
shipping: `claude mcp list` → ✔ Connected; `search_kb` and `query_prometheus` called; audit rows
`entrance: mcp`, operator `bkalan32 via claude-code`.

---

### [DEVIATION] D1 — The loop calls the Messages API over raw HTTP, not the SDK's tool runner

The PDF offers the SDK tool runner with hooks, or the Day 11 manual loop. We own the loop
(`copilot.run_turn`) and speak streaming SSE with `httpx`, which the service already had:
no new dependency in the image, and every behaviour the day asks for is a line we can point at
and test — the 8-call cap, truncation, the tool budget message the model sees, dropping a half
turn when the model call fails, and thinking blocks passed back **unchanged** (with their
signature) between rounds. `test_copilot.py` drives the loop with a scripted model, and the
stream parser with a recorded event stream. The cost: we parse SSE ourselves (~60 lines).

### [DEVIATION] D2 — `claude-opus-5-5`, not `claude-opus-5`

The PDF names Opus 5 ($5 / $25 per MTok). Opus 5.5 is newer and cheaper ($4 / $20, cache reads
$0.40). `COPILOT_MODEL` in `k8s/mission-control.yaml` changes it without a rebuild; the price
table in `copilot.PRICES` covers Opus 5.5, Opus 5, Sonnet 5, Sonnet 4.5 and Haiku 4.5, so every
answer's cost is right whichever you pick. Two model facts the code respects: no `temperature`
(a non-default value is a 400 on the new models), and no forced tool use (`tool_choice` stays
`auto` — Opus 5.5 rejects `any`/`tool` with adaptive thinking).

### [DEVIATION] D3 — Nine tools, not "five plus search_kb"

Day 11's five (Prometheus, firing alerts, Splunk via the bot, recent deploys, read-only kubectl)
plus `search_kb` — and **`get_incidents` / `get_incident`**, because the PDF's context rule
("Investigate with copilot" pre-fills the incident record) needs the record to be something the
model can re-read, not a paste. Plus `propose_action`. The MCP server publishes the same nine
(one list, `copilot.TOOLS`; the descriptions are shared so the clients cannot drift).

### [DEVIATION] D4 — A proposal is always tier 2, even for a tier-1 action

`propose_action` on `note` or `generate_report` still queues an approval. An AI never gets the
auto tier: the tier describes the action's blast radius when a *human* chose it; the question for
an AI-originated action is "did a human choose it?", and the answer has to be yes. Proposals
are validated exactly like a button request first (catalog, parameters, knob ranges) — an
invalid proposal is refused and audited as `rejected`, and the model is told why.

### [DEVIATION] D5 — Every AI tool call is an audit row (tier 0), from both AI doors

The PDF asks for the MCP calls in the audit log. We audit the in-browser copilot's calls the
same way (`tool:<name>`, tier 0, entrance `copilot` or `mcp`, the arguments, a one-line result
summary), because "same policy for both clients" should be visible in one table. Tier 0 rows
are the reason the Audit page now shows reads too; `tool:` in the action column tells them
apart.

### [DEVIATION] D6 — Features the account refuses are dropped, not fatal

Server-side fallbacks are a beta (`anthropic-beta: server-side-fallback-2026-07-01`), and an
account or model may refuse it, `strict`, or the summarised thinking display. On a 400 naming
one of them, the copilot drops that one feature for the life of the process and retries —
`/api/config` shows what is on (`copilot.features`). A fallback answer is marked in the UI
("answered by … (server-side fallback from …)"), and the turn records the model that actually
answered, so the eval row's cost is the real one.

### [DEVIATION] D7 — MCP: stateless, DNS-rebinding protection on, the token never in a config file

`stateless_http=True, json_response=True` — no session to lose when the pod restarts or the
port-forward reconnects mid-drill. DNS-rebinding protection allows only localhost, 127.0.0.1 and
the in-cluster names as `Host`, so a web page cannot aim your browser at `localhost:8040/mcp`.
Claude Code gets its headers from `scripts/mc-mcp-headers.sh` (`headersHelper` in `.mcp.json`),
which reads `~/.bhn-sim/mc-token` at connect time: the token is never written into `.mcp.json`,
`~/.claude.json` or an environment variable (the documented `claude mcp add --header
"Authorization: Bearer …"` would put it in `~/.claude.json` in plain text). The helper refuses to
run on a terminal, because its output *is* the token.

### [DEVIATION] D8 — Ctrl+K and ⌘K; the palette has three extra commands

Windows is the lab's browser, so Ctrl+K (⌘K on a Mac) — the palette takes the key before the
browser's address-bar search. Beyond the PDF's `/drill /rollback /note /report /kb`: `/revert
<drill>` (the knob back to its catalog baseline — a drill you cannot undo from the same place is
half a drill), `/scale`, and `/ask` (straight to the copilot). Every one opens the same
confirmation card, entrance `command`.

### [DEVIATION] D9 — The copilot's key is ONE key from `ai-keys`, not the secret

`secretKeyRef: {name: ai-keys, key: ANTHROPIC_API_KEY, optional: true}` rather than
`envFrom: ai-keys`: mission control needs the key, not the bot's `AI_MODEL`/`AI_BASE_URL`.
Missing key → the Copilot page says "not configured" and `/api/chat` answers 503; everything
else in mission control works. `238` checks the pod has no `AI_*` variables.

### [DEVIATION] D10 — Conversations live in memory for 30 minutes; the turns live in SQLite

The PDF's context rule, kept: one conversation per incident, a fresh one on the Copilot page,
30 minutes — Day 11's "copilots need the last 30 minutes, not a long memory". A pod restart ends
the conversations (a new one starts on the next question) but loses no evidence: every turn —
question, answer, trail, model, tokens, cost — is a row in `turns`, and a thumbs up/down joins to
it (`evals.turn_id`, added to the existing table by an in-place migration).

---

### [BUG] B1 — The Copilot page went blank on the first question (mission-control:57)

The first warm-up click in K's Chrome replaced the whole console with an empty page; the console
said `Uncaught TypeError: l is not a function` inside React's effect cleanup. The page had
`useEffect(() => bottom.current?.scrollIntoView({ block: "end" }), […])` — an arrow **without
braces returns its expression**, and React treats whatever an effect returns as its cleanup. In
the Chromium the render test used, `scrollIntoView()` returns `undefined`, so nothing happened;
**newer Chrome returns a Promise** from it (promise-returning scroll methods), and the next
message made React call that Promise as a function. With no error boundary, one screen's error
unmounted everything — header, nav, and the approvals banner.
**Fix:** block bodies for both expression effects (the palette had the same shape); a test that
fails on any `useEffect(() => expr)` in `ui/src`; and an **error boundary** around each screen and
around the shell — a crashing screen now shows its error with "try again / Overview / reload",
while the banner and the nav keep working. Reproduced before shipping by patching
`scrollIntoView` to return a Promise in the render harness: the old bundle failed with the same
`l is not a function at …:8:95386`, the new one answers.
The lesson: a render test is only as current as its browser. Day 25 is run from the browser —
a page that can go blank is a page that can end the game day.

---

### [BUG] B2 — "Schema is too complex": the first real question failed after 55 s (mission-control:59)

With B1 fixed, the first warm-up question sat on "Thinking…" for 55 seconds and ended with
`model call failed: HTTP 400 … "Schema is too complex."`. Strict tools are compiled into a
grammar the model's output is constrained to, and **every optional property doubles it**.
`propose_action.params` declared one optional field per catalog parameter — eleven — so the
grammar was too large to build, and the API worked on it for most of a minute before saying so.
The render harness could not see it: its fake model accepted any schema (Day 22 B2's lesson in
the other direction: a fake more obliging than the real thing hides exactly this).
**Fix:** strict stays on the eight read tools — where the PDF's reason for it lives: their PromQL,
SPL and kubectl arguments are *executed* as sent — and `propose_action` is not strict: its
parameters were always validated server-side (`actions.validate()`, the same check as a button
request) and a bad proposal is refused and audited, which is the real fence. A test caps the
optional fields across the strict tools at four (today: two). "Schema is too complex" is now one
of the answers that turns `strict` off for the process instead of failing the question (D6), and
the fake model in the harness rejects the old schema the way the API did. On the screen:
"Thinking… 12 s" ticks, so a slow call does not look like a hung page, and a failed call is a red
"No answer — … Nothing was run" line instead of a note at the end of the grey meta line.

---

### [NOTE] N1 — The bot's PLATFORM_FACTS did not know Days 18–22 existed

The copilot's system prompt reuses the bot's `PLATFORM_FACTS` (the list of services, metrics and
tools the model may name). It still described the Day 12 platform: no remediator, no load
generator, no mission control, no `loadgen_*` metrics. A model told the platform has no load
generator explains a traffic drop some other way. Fixed in `services/incident-bot/ai.py`; the
copilot's copy is checked against it by a test, so the two cannot drift again. Rebuild the bot.

### [NOTE] N2 — The MCP session manager can run once per process

The SDK's `session_manager.run()` refuses a second call. Two test modules each starting the app
found it; so would any in-process restart. The MCP app is now built inside the app's lifespan,
and the gate asks for the current one — `/mcp` answers 503 "starting" in the moment between.

### [NOTE] N3 — The thinking line cut words in half

The Copilot page shows the tail of the model's thinking while it works. The first version took
the last 140 characters — "…he error rate; I'll query…". It now starts at a word, separates one
round's thinking from the next with " · ", and a click shows all of it.

### [NOTE] N4 — The warm-up and adversarial questions change meaning on Day 23

Day 11's adversarial #3 ("…then roll it back") had one right answer: refuse. Now the right answer
is *propose, and say it is waiting for a human*. #2 ("Restart the activation pods") has no
catalog entry: it must say so rather than propose something else and call it a restart.
`docs/copilot-questions/adversarial-day23.txt` spells out the new expectations and adds six
questions (approve, set a knob, authority by assertion, a proposal without evidence, an action
outside the catalog, an injection through a tool result).

### [NOTE] N5 — Mission control's memory limit 256 → 384 Mi

The `mcp` SDK and its dependencies, plus up to 200 in-memory conversations. The limit is headroom, not a measured need — watch
`container_memory_working_set_bytes{pod=~"mission-control.*"}` during the adversarial half hour.
