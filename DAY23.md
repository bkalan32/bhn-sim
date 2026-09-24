# Day 23 — Mission Control, part 3: the copilot, the command palette, the MCP server

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 23 · adapted to this lab.
Corrections: `CORRECTIONS-DAY23.md`.

## What we are building, and why

Days 9–11 built an AI that could *read* the platform — drafts on incidents, then a terminal
copilot (`tools/copilot.py`) that queried Prometheus and Splunk and was told "diagnosis only".
Day 23 moves that AI into mission control and moves the line **one honest step**:

**The copilot, server-side.** Same tools (plus the KB and the incident records), now with strict
schemas, adaptive thinking you can watch, prompt caching, the eight-call cap, and a new tool —
`propose_action`. The AI may now say "I recommend rolling back activation, here is why", and the
recommendation becomes a **card in the approvals banner**. It never executes; a human's click
does. Same evidence, same tier, same audit row as a human asking.

**The Copilot screen.** Chat on the left, the **tool trail** on the right: every query the model
ran, exactly as it ran it. Day 11's lesson — watching which queries it chooses is how you learn
to trust it — becomes a permanent part of the screen. An answer with no trail is visibly an
answer with no evidence. Under every answer: 👍/👎 and a one-line note → an eval row with the
question, the trail, the answer, the model, the tokens and the cost. `docs/ai-eval.md` becomes
the **Evals** page — grading costs one click, which is the only way it survives a busy week.

**The command palette.** Ctrl+K anywhere: screens, the action catalog, the KB, and slash
commands (`/drill fraud`, `/rollback activation`, `/note …`, `/report`, `/kb settlement`,
`/ask …`). The third entrance to the same catalog — it opens the same confirmation card and
skips no tier.

**The MCP server.** The same nine tools, published on `/mcp` behind the same token. Claude Code
in your terminal can now investigate the platform *through* mission control, with the same
allow-lists and the same audit log (entrance `mcp`). One tool surface, two AI clients, one
policy — the shape "engineering assistants" take in real companies now.

Why now: game day 3 (Day 25) is run from the browser. The copilot is the terminal you will not
have, and the palette is how you reach an action in two keystrokes under pressure.

## What changed in the repo

| Where | What |
|---|---|
| `services/mission-control/copilot.py` | the loop: raw streaming Messages API, adaptive thinking (summarised), strict tools, cache breakpoints, server-side fallback, 8-call cap, truncation, the kubectl allow-list, `propose_action` |
| `services/mission-control/mcp_server.py` | the MCP server (mcp SDK 2.2): nine tools, stateless, DNS-rebinding protection, behind `MCPGate` (the bearer token) |
| `services/mission-control/app.py` | `POST /api/chat` (SSE), `GET /api/chat/turns`, every AI tool call audited (tier 0, `tool:<name>`), proposals → tier-2 approvals, `/api/eval` grades a copilot turn, `/mcp` |
| `services/mission-control/db.py` | `turns` table (question, answer, trail, model, tokens, cost); `evals.turn_id` (migrated in place) |
| `services/mission-control/ui/` | Copilot page, Evals page, the command palette, "Investigate with copilot →" on the incident page |
| `k8s/mission-control.yaml` | `ANTHROPIC_API_KEY` from `ai-keys` (one key, optional), `COPILOT_MODEL`, memory 384Mi |
| `services/incident-bot/ai.py` | `PLATFORM_FACTS` knows the remediator, the load generator and mission control (N1) |
| `.mcp.json`, `scripts/mc-mcp-headers.sh` | Claude Code's config for the MCP server — the token is read at connect time, never stored |
| `scripts/230-mcp.sh` | is `/mcp` ready for Claude Code? |
| `docs/mcp.md`, `docs/copilot-questions/adversarial-day23.txt` | how to connect a client; the new break-it questions |
| `scripts/238-checkpoint-day23.sh` | the exit criteria |

## Steps

1. **Unpack, test** — the new `mcp` package goes into the service's venv first:
   ```
   cd services/mission-control && python3 -m venv .venv && . .venv/bin/activate
   pip install -q -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests; deactivate; cd ../..
   ```
   57 pass. The bot the same way (`services/incident-bot`): 36 pass.
2. **The key.** Mission control reads `ANTHROPIC_API_KEY` from `secret/ai-keys` — the one
   `90-ai-secret.sh` made on Day 9. `./scripts/90-ai-secret.sh --check` confirms it works. Nothing new to store.
3. **Commit and push** (Jenkins builds from GitHub).
4. **Ship both images** — Jenkins `deploy-service`: `SERVICE=mission-control`, then `SERVICE=incident-bot`.
5. **Open it:** `./scripts/220-mc-open.sh`. The Copilot tab is live; the header says the model.
6. **The warm-up, from the browser** (PDF "done when" #1). Copilot → the five **Warm-up**
   buttons (Day 11's `warmup.txt`), one at a time. For each: read the trail — right tool? right
   query? right reading? — then 👍 or 👎 with a one-line note. Check one number against Grafana
   yourself.
7. **A proposal, granted by a human** (#2). Open an incident (or start a drill with `/drill fraud`
   from Ctrl+K and approve it in the banner), click **Investigate with copilot →**, ask
   *"what should we do?"*. When it proposes, the card appears in the banner "via copilot" —
   **Approve** it (or decline it and say why). Revert any drill with `/revert fraud`.
8. **The palette** (#3). Ctrl+K: "incidents" (a screen), "rollback" (an action — Cancel), "fraud"
   (a KB entry), `/note` on an incident page, `/report`, `/kb settlement`.
9. **MCP from Claude Code** (#4) — `docs/mcp.md`: `./scripts/230-mcp.sh`, then
   `export MC_OPERATOR=bkalan32; claude` in `~/bhn-sim`, approve the `bhn-sim` server, ask
   *"which store had the most activation errors in the last 30 minutes?"* and
   *"what does the KB say about fraud timeouts?"*. Watch the Audit page: entrance **mcp**.
10. **The adversarial half hour** (Step 5) — `docs/copilot-questions/adversarial.txt` and
    `adversarial-day23.txt`, in the browser *and* through Claude Code. Grade every browser answer
    with a thumb; write the MCP ones and a summary as **Eval 13** in `docs/ai-eval.md`.
11. `./scripts/238-checkpoint-day23.sh`.

**Cost.** The copilot runs on `claude-opus-5-5` ($4 in / $20 out per million tokens; cached
input $0.40). A warm-up question is ~10–15k input tokens, mostly cached after the first, and
~$0.02–0.06. The whole day is a couple of dollars. Every answer shows its own cost.

## The questions to ask yourself while grading

- Did it **query** or **recall**? A number without a `query_prometheus` card is a guess.
- Did it read the result it got, or the one it expected? (Day 11: `rate()` vs `increase()`.)
- When it proposed an action: was the evidence in its own trail? Did it say the action is
  *waiting*, not *done*?
- When it could not do something (approve, restart, read a secret): did it say so plainly, and
  say what a human would do instead?

**Done when:** `238` passes — warm-up turns with trails, a copilot proposal granted from the
banner by a human, palette rows in the audit (entrance `command`), Claude Code's `tool:search_kb`
and `tool:query_prometheus` rows (entrance `mcp`), graded copilot answers on the Evals page,
Eval 13 written, plan clean.
