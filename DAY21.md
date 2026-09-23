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

## Steps 2–5 — the API

`services/mission-control/`: `app.py` (routes, auth, the one `run_action` path every entrance
takes), `actions.py` (the catalog — tier, parameters, validator, executor), `db.py` (audit log,
approval queue), `events.py` (the SSE broker), `config.py`. 21 tests cover what the graduation
bar checks: 401 without a token, tier 1 runs and is audited, tier 2 does nothing until a human
approves, a token works once, the copilot/MCP entrances can propose but never approve, bad
parameters never reach the queue, a slow browser never blocks the feed.

**Ship it (the pipeline, like everything since Day 6):**

1. `./scripts/210-mc-config.sh` — read-only RBAC outside `payments`, the bearer token (into a
   Secret and `~/.bhn-sim/mc-token`, never printed), your Jenkins API token (Jenkins → your name
   → Security → API Token → Add). It proves RBAC once the ServiceAccount exists.
2. Jenkins `deploy-service` → `SERVICE=mission-control`. Verify is the bot's: up 30 s, no restarts.
3. `./scripts/210-mc-config.sh --check` — the API server's answer: 9 yes, 9 no.
4. `./infra/local/tf.sh plan` → one change (kps: the third webhook) → `apply`.
5. `kubectl -n payments port-forward svc/mission-control 8040:8040` (own terminal), then
   `python3 tools/mc.py overview`.

**The drill that proves Steps 2–5 — the fraud outage, driven through Mission Control:**

| Terminal | Command | What it proves |
|---|---|---|
| A | `python3 tools/mc.py events` | the live feed (Step 5) |
| B | `python3 tools/mc.py run rerun_settlement` | tier 1: runs, audit row, `audit` event in A |
| B | `python3 tools/mc.py run set_fault target=activation knob=FRAUD_SVC_DOWN value=true --reason "Day 21 drill"` | tier 2: queued, nothing changes |
| B | `kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].env}'` | still `FRAUD_SVC_DOWN=false` |
| B | `python3 tools/mc.py approvals` then `approve <token>` | the second click; audit row with the token |
| A | watch | `ActivationHighErrorRate` arrives as an `alert` event — **wait for it, ~4 min**: pod restart ~20 s + the 2 m rate window crossing 10 % + `for: 2m` + `group_wait` 15 s. Revert before it arrives and the alert never fires |
| B | `python3 tools/mc.py run set_fault target=activation knob=FRAUD_SVC_DOWN value=false --reason revert` + approve | the fix has the same ceremony |
| B | `python3 tools/mc.py audit` | the whole drill, in order, with names and tokens |

**Done when:** `./scripts/218-checkpoint-day21.sh` passes — chores shipped, one JSON overview under
2 s, 401 without a token, a tier-1 and an approved tier-2 row in the audit log, a tier-2 request
that changes nothing until approved, a declined token dead, RBAC forbidding `kubectl delete
deployment` from inside the pod, the third webhook live, the feed fed, the plan clean.
