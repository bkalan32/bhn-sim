# Day 21 — Mission Control, part 1: the chores, then the control-plane API

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 21 · adapted to this lab
(Windows + WSL2, kind, the rebuilt platform of 23 Sep 2026). Corrections: `CORRECTIONS-DAY21.md`.

## What we are building, and why

Twenty days built a platform you operate from a terminal: `kubectl`, drill scripts,
`copilot.py`, `rem.py approve`, markdown you edit by hand. Days 21–25 build **Mission Control**
— one web app (a FastAPI control plane in the cluster on :8040, a React UI it serves from `/`)
that puts all of it behind a browser — and end with **game day 3 run with the terminal closed**.

One design rule runs through all five days, and it is written at the top of
`docs/mission-control.md`: **one action catalog, three entrances.** A button, a `/slash`
command and a copilot proposal are three ways to reach the *same* catalog entry, which goes
through the *same* tier check, the *same* RBAC and writes the *same* audit row. If an entrance
can do something the others cannot, it is a bypass.

Day 21 is the part with no UI: first three chores the platform needs before anything can sit on
top of it, then the API itself.

## Step 1 — three chores (today's first half)

| Chore | Why now | Where |
|---|---|---|
| **incident-bot → SQLite** (`incidents` + append-only `timeline`) | Mission Control asks "open incidents since 10:00" every few seconds; a directory of JSON files answers by parsing every file. The Day 8–20 files are imported on first start. | `services/incident-bot/store.py`; `GET /incidents?status=open&since=` |
| **remediator's proposals and cooldowns → SQLite** | A deploy of the remediator forgot a pending approval *and* a cooldown — both on the safety path. Tokens become single-use by construction. | `services/remediator/state.py`; PVC `remediator-data` |
| **load generators → a Deployment** with `RATE_MULTIPLIER` (0–10) | Traffic must be a knob Mission Control can turn (tier 2), not a laptop terminal. `/metrics` says whether it was turned down on purpose. | `services/loadgen/`, `k8s/loadgen.yaml`, Jenkins `SERVICE=loadgen` |

All three ship **through the pipeline** (deploy-service), like every service since Day 6.

**Done when (Step 1):** the OTel ticket from the rebuild is still there after the bot moved to
SQLite *and* after a restart; a proposal survives a remediator restart and cannot be used twice;
traffic runs from `deployment/loadgen`, the laptop generators are stopped, and
`loadgen_rate_multiplier` is in Prometheus.

## Steps 2–5 — the API (after Step 1 is green)

Step 2 the routes (`/api/overview`, `/api/events` SSE, incidents, approvals, actions, chat, KB,
reports, KPIs, audit, eval) · Step 3 `actions.py`, the catalog, and mission control's own
ServiceAccount and Role · Step 4 auth (bearer token from a Secret, `X-Operator`) and the audit
table · Step 5 the event stream (Alertmanager's third receiver, through Terraform) and health
scores every 15 s. Written up here as they are built.
