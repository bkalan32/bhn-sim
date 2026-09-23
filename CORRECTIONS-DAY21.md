# Day 21 — Corrections Log

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 21 · Built from 23 Sep 2026, on the
lab rebuilt that afternoon (`CORRECTIONS-REBUILD.md`).

---

## Step 1 — the chores

### [BUG] B1 — "Incidents survive restart" was already true; what the rebuild lost was the node

The PDF frames chore 1 as persistence. The bot has written to a PVC since Day 8 (Day 8 B3 — the
PDF's emptyDir would have lost records on every deploy); records survived every restart and
rollout for twelve days. What lost them on 23 Sep was the **kind node** dying with Docker —
and a PVC on kind lives inside that node. SQLite on the same PVC does not change that
(`CORRECTIONS-REBUILD` N1). What it does buy is the reason to do it now: **queries** (Mission
Control's "open since T, newest first" is one indexed SELECT instead of parsing every file),
**transactions** (the incident row and its new timeline events commit together), and an
**append-only** timeline enforced by the store, not by convention.

### [DESIGN] D1 — stdlib `sqlite3`, not SQLModel/aiosqlite, for the bot and the remediator

The PDF's stack lists SQLModel + aiosqlite for Mission Control. The bot and the remediator are
threaded (drafts, enrichment and actions run in background threads by design, Day 9 B1), have two
tables each, and already shipped without an ORM. `store.py` / `state.py` use `sqlite3` with one
connection per thread, WAL (readers never block the webhook) and a 5 s busy timeout. Mission
Control, which is async end to end, is where the PDF's stack fits; it gets it in Step 2.

### [DESIGN] D2 — The load generators are ONE Deployment with TWO containers

The PDF says two Deployments. The pipeline's unit is a Deployment named after its SERVICE —
rollout status, the restart check, rollback, change-cause and the Grafana annotation all key on
`deployment/<SERVICE>` — so two Deployments would need a special case in the Jenkinsfile. One
`deployment/loadgen` with containers `activation` and `egift` ships through the same door as
everything else; each is still its own knob because env is per container (`kubectl set env
deployment/loadgen -c activation RATE_MULTIPLIER=0`). Cost, accepted: turning one knob restarts
the pod, so both targets blip for a few seconds. `strategy: Recreate` — two generators during a
rollout would double the traffic and look like an incident.

### [BUG] B2 — The remediator forgot two things on restart, not one

The PDF moves `PENDING` to SQLite. The cooldown (`LAST_ACTION`) was in memory too, and it is the
more dangerous one to lose: a remediator deployed two minutes after acting would act again on the
same still-firing alert — the loop the cooldown exists to stop. Both persist in `state.py`.

### [DESIGN] D3 — A token is single-use by construction

Approve and decline both call `state.take()`: one `DELETE FROM pending WHERE token = ? AND
expires_at > now RETURNING doc`. The row is removed by the statement that reads it — two
clicks, two tabs, or a click racing the expiry sweep get one winner and one 404. Tested with
eight threads on one token (`test_concurrent_takes_have_one_winner`). The PDF's troubleshooting
note ("Tier 2 approval succeeds twice") is answered before Mission Control has a button. One
detail found while writing it: a `RETURNING` statement in Python's `sqlite3` is only finished
— and in autocommit mode only committed — when its rows are exhausted; `fetchone()` would leave
the write lock held. `fetchall()`, and a test that takes the lock from another connection after.

### [BUG] B3 — The load generator waited for each answer: "coordinated omission" since Day 2

First in-cluster run (loadgen:50): configured 5 req/s → **3.5–4.0**; configured 3 → **1.9–2.1**
(egift is slower, because each order calls activation). The generator sent a request, *waited
for the answer*, then slept — so every millisecond of service latency came out of the send rate.
The laptop version did the same for nineteen days (8 configured, ~4.5 seen). The part that
matters: under Day 25's latency fault (`BASE_LATENCY_MS=400`) activation traffic would have
**halved** — the error-rate and burn-rate denominators with it, and the health score computed
over half the customers. The generator was hiding the very degradation it exists to expose; load
testing calls this *coordinated omission*, and real customers do not queue behind each other.
**Fix:** open loop — each send is scheduled from the previous *send*, requests run on a bounded
pool (`MAX_INFLIGHT` 32); a full pool is counted as `dropped_client_busy`, never silently delayed.
Test: answers that take 0.4 s at 10 req/s configured → ≥ 12 sent in 2 s (closed loop: ~4).

### [NOTE] N1 — The load generator now says when it was turned down on purpose

`loadgen_requests_total{target,outcome}`, `loadgen_target_rps`, `loadgen_rate_multiplier`
(PodMonitor — nothing calls the generator, so no Service). On Day 25 the "traffic loss" fault
asks whether a responder notices silence; `loadgen_rate_multiplier == 0` is how the platform can
tell "someone turned traffic off" from "the generator died" from "customers stopped coming".

### [NOTE] N2 — For Day 25: activation never reaches zero while egift has traffic

Every egift order calls activation. With `loadgen/activation RATE_MULTIPLIER=0`, activation still
sees ≈ `BASE_RPS(egift)` = 3 req/s. Scenario-3's step 3 ("traffic drops to zero") needs both
knobs at 0, or the `ActivationNoTraffic` rule it motivates must be written knowing this.

### [NOTE] N3 — The remediator's kubectl is v1.32; the cluster is v1.37

`services/remediator/Dockerfile` pins `KUBECTL_VERSION=v1.32.0` with a comment that says "one
minor version either side of the cluster is supported". The cluster is five minors ahead. The
three verbs it uses work; it was outside the support window all the same. Fixed in the same
build as the state change: `v1.37.0`. Mission Control's image (Step 3) pins the same.

### [NOTE] N4 — Proven in the cluster, not only in the tests (remediator:49)

A proposal planted straight into `/data/remediator.db`, a `rollout restart`, and the new pod
listed it; the first decline succeeded, the second got a 404. The run also crashed
`tools/rem.py pending` with `KeyError: 'created_at_iso'` — the planted row lacked the display
fields a real proposal carries. The drill's fault, but the lesson is the CLI's: a listing that
dies on one incomplete record hides every *other* pending approval from the person who has to
act on them. `rem.py` now reads every field with a default.

