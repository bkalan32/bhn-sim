**One action catalog, three entrances.** A button, a slash command and a copilot proposal are three ways to reach the same entry in `services/mission-control/actions.py`, and every one of them goes through the same tier check, the same RBAC and writes the same audit row. If an entrance can do something the others cannot, it is a bypass — and a bug.

# Mission Control

The control plane for the platform built in Days 1–20: one FastAPI service in the cluster
(`services/mission-control/`, :8040, one replica, a PVC) and, from Day 22, the browser UI it
serves from `/`. Built Days 21–25; the graduation test is game day 3 run with the terminal closed.

## What it owns, and what it does not

| Owns | Does not own (reads from) |
|---|---|
| the **action catalog** (`actions.py`) — every write the platform can make on a human's behalf | incidents — the **incident-bot** (`GET /incidents`, SQLite since Day 21) |
| the **audit log** — one row per attempt, any entrance | remediator proposals — the **remediator** (`/pending`, SQLite since Day 21) |
| the **tier-2 approval queue** — single-use tokens, 30 min | metrics and health scores — **Prometheus** |
| the **live feed** (SSE) | alerts — **Alertmanager** (API + a third webhook) |
| | deploys — **Grafana** annotations (written by the pipeline) |

A second copy of someone else's data is a second answer that can disagree. Mission Control
shows; the owners keep.

## Tiers

| Tier | Meaning | In the catalog | What a click does |
|---|---|---|---|
| 0 | read | every GET | nothing to audit |
| 1 | auto | note, rerun_settlement, delete_crashlooping_pod, run_drift_check, generate_report | validate → execute → audit row → toast |
| 2 | approve | rollback, scale, deploy, silence_alert, set_fault | validate → **queue** (token, 30 min) → audit `pending`; a human's second click executes, audit `ok` with the approver's name and the token |
| 3 | human | *nothing* | no button exists; the UI says escalate, with the KB entry's fix text |

Fault knobs are tier 2: breaking production on purpose has the same ceremony as fixing it.

## Entrances

`X-Entrance` on every request: `button` (the UI), `command` (the Cmd+K palette, Day 23),
`copilot` (Day 23), `mcp` (Day 23), `api` (tools/mc.py, curl). **Only button, command and api
may approve.** The copilot and MCP may *propose* a tier-2 action — it lands in the same queue
with `entrance: copilot` — and may never approve or execute one. That is enforced in `app.py`
(`HUMAN_ENTRANCES`), tested (`test_the_ai_can_propose_but_never_approve`), and audited
(a refused approval is itself a row).

## Security, in one table

| Control | Where |
|---|---|
| bearer token on every `/api/*`, empty token = refuse everything | `app.py caller()`; secret/mission-control-auth (`210`) |
| `X-Operator` on every write | `app.py writer()` |
| ServiceAccount + Role: patch deployments, create jobs, delete pods, patch cronjob/settlement, get cm/kb; **no** secrets, **no** delete deployments | `k8s/mission-control.yaml`; proven by `210 --check` |
| read-only in monitoring / tracing / logging | `k8s/mission-control-rbac.yaml` |
| kubectl as argv, verb allow-list | `actions.py kubectl()` |
| every parameter validated before it can be queued; knobs allow-listed with ranges | `actions.py validate()` |
| `/hooks/alertmanager` is display-only and ClusterIP-only | `app.py am_hook()` |
| tokens never printed; Jenkins credentials on stdin | `210`; `~/.bhn-sim/mc-token` (600) |

## The UI (Day 22)

Served by the same container from `/` (`services/mission-control/ui/`, built in the image's
first stage). The page is public — it is a login form until you give it a name and the token —
and every byte of data behind it is under `/api/`.

| Screen | Day | What it is for |
|---|---|---|
| Overview | 22 | the ten-second screen: scores + 1 h sparklines, critical alerts, open incidents, deploys, settlement age, the live feed, embedded Grafana panels, the last ten audit rows |
| Incidents | 22 | the list (open first) and the incident page: context with deep links, hypothesis + KB chips, timeline + note box, actions rail, AI drafts with copy and 👍/👎 |
| Knowledge Base | 22, 24 | cards: symptoms, checks with *run in copilot →*, fix, learned-from links; read-only (the KB is git + `172-kb.sh`) |
| Audit | 22 | every tier 1 / tier 2 attempt, any entrance; from Day 23 also every AI tool call (tier 0, `tool:<name>`) |
| Copilot | 23 | chat + the tool trail (every query, exactly as run); answers stream with a thinking line; 👍/👎 + note → an eval row; proposals land in the banner |
| Evals | 23 | every grade of an AI output — copilot answers (question, trail, answer, tokens, cost) and incident drafts |
| Game Day | 24 | every fault knob live (tier-2 changes), sealed scenario runs (one approval, steps hidden until Retro), Reset all, run skeletons |
| KPIs | 24 | the seven Day 18 KPIs with 4-week trends and definitions; MTTD measured from the console's injections; the incident table |
| Reports | 24 | the daily report archive, Generate now, three days side by side, 👍/👎 per report |

**On every page:** the pending-approvals banner. Approve there is the human's second click for
anything waiting — requested by you, by the remediator, or (Day 23) by the copilot.

**Opening it:** `./scripts/220-mc-open.sh` — port-forwards for Mission Control (:8040) and
Grafana (:3000, the browser loads the embedded panels itself), each reconnecting after a pod
restart; the token onto the Windows clipboard, never printed; the browser.

**In the browser, the security table continues:**

| Control | Where |
|---|---|
| token kept in sessionStorage — this tab only; never localStorage, never a cookie | `ui/src/lib/session.ts` |
| Content-Security-Policy: scripts and fetch/SSE to itself only, iframes from Grafana only, not frameable | `app.py _csp()` |
| Grafana panels as an anonymous **Viewer** (an iframe cannot carry a token); admin pages refused | `k8s/kps-values.yaml`, proven by `228` |
| every write sends `X-Entrance: button` — the audit says which door | `ui/src/lib/api.ts` |

## The copilot and the MCP server (Day 23)

`services/mission-control/copilot.py` is the loop; `mcp_server.py` publishes the same tools on
`/mcp` (`docs/mcp.md`). Ten tools: nine reads and `propose_action`. The policy, in one table:

| Control | Where |
|---|---|
| strict tool schemas, `additionalProperties: false` — the PromQL/SPL/kubectl arrive as declared | `copilot.TOOLS`, `api_tools()` |
| kubectl: read verbs only; no secrets, configmaps or service accounts; platform namespaces; no `-A`; logs ≤ 80 lines | `copilot.check_kubectl()` |
| every tool result truncated (6,000 chars); 8 tool calls per question | `copilot._truncate`, `TOOL_CALL_BUDGET` |
| `propose_action` validates like a button, then **queues** a tier-2 approval — any tier, any action | `app.py propose()` |
| no approve tool; approval routes refuse `copilot` and `mcp` | `HUMAN_ENTRANCES` |
| every tool call audited: `tool:<name>`, tier 0, entrance `copilot`/`mcp`, who asked | `AuditedHands` |
| `/mcp`: same bearer token; DNS-rebinding protection; stateless | `MCPGate`, `mcp_server.build()` |
| the model never sees a secret: the key is mission control's env, the tools cannot read secrets | `k8s/mission-control.yaml`, `check_kubectl` |

The **command palette** (Ctrl+K / ⌘K) is the `command` entrance: screens, the catalog, the KB,
and `/drill /revert /rollback /scale /note /report /kb /ask` — each opens the same confirmation
card as the button.

## The Game Day console (Day 24)

`gameday.py`. Scenarios are `gameday/*.yaml` (ConfigMap `gameday`, `240-gameday.sh`); a run is one
tier-2 approval (`run_scenario`), executed server-side through the `set_fault` executor, resumed
after a restart. **Sealed** = not revealed, not reset, not aborted — and while sealed, nothing shows
the plan: not the page, not the knob panel, not the audit (`scenario_step` rows carry run + step and
the approval token, never the knob), not the feed, not the Grafana markers (tags `gameday` + run id,
never a service name — the bot's deploy collector reads by service tag). Retro appends the real
audit rows, PATCHes the markers and unlocks the run skeleton (`245-gameday-run.sh` saves it). Reset
all (`reset_faults`, tier 1) aborts a running schedule, then returns every off-baseline knob.
