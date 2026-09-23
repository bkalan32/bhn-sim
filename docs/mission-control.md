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
| Knowledge Base | 22 | where the KB chips land; read-only (the KB is git + `172-kb.sh`) |
| Audit | 22 | every tier 1 / tier 2 attempt, any entrance |
| Copilot | 23 | |
| Game Day, KPIs & Reports | 24 | |

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
