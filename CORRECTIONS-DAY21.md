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
Control is async end to end, so it uses **aiosqlite** — but not SQLModel: two tables (audit,
approvals) and one of them append-only do not need an ORM, and the single-use token is one
`DELETE … RETURNING` that an ORM would only hide.

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

### [BUG] B4 — Every build made the control plane restart itself

After Step 1's builds: `kube-controller-manager` **8 restarts**, `kube-scheduler` **5** — the
latest pair within one second of each other, ~6 min after the old-image cleanup; the Prometheus
operator, kube-state-metrics and Tempo restarted together ~20 min earlier, at the loadgen build.
`PlatformPodRestarting` opened INC-1790188371-f098 at 18:32:51Z. Load average at the time of
reading: 1 now, 8 over 5 min, 12 over 15 — storms that come and go with every Docker-heavy
operation (`docker build`, `kind load`, `docker rmi`), because the build and the cluster share the
same 8 CPUs. The two control-plane components hold leader **leases** (15 s, renew deadline 10 s);
a starved node misses a renewal, the component gives up leadership and exits. Leader election is
for failing over between replicas — a one-node lab has nothing to fail over *to*. **Fixes:**
(1) `scripts/136-control-plane-leases.sh` — lease 60 s / renew 40 s / retry 10 s in the static pod
manifests (and in `docs/rebuild.md` step 1); (2) the Jenkinsfile caps `docker build` at 2 CPUs.
The platform's own alert found this, which is what Day 14 put it there for.

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

### [NOTE] N5 — The kind config said the node image was pinned; it never was

`kind/bhn-sim-cluster.yaml`'s header, since Day 1: *"A pinned node image — so a kind upgrade six
days from now does not silently change your Kubernetes version mid-series."* The file had no
`image:` line; both clusters today got v1.37.0 only because the installed kind defaults to it.
Now pinned by digest (the image the rebuild ran on). A comment describing code that is not there
is worse than no comment: it is a claim nobody re-checks.

---

## Steps 2–5 — the API

### [BUG] B5 — The PDF's port map assumes one DNS; the lab has two

The PDF lists Jenkins at `:8080` and Splunk at `:8089` next to in-cluster Services as if all were
reachable by name. Jenkins and Splunk are Docker containers on the `kind` network, not pods:
kind's CoreDNS cannot resolve their container names (the reason the bot has carried Splunk's IP
in `enrich-config` since Day 10). `scripts/210-mc-config.sh` renders Jenkins's container IP into
`secret/mission-control-config` and repairs it when a Docker restart moves it. From the laptop,
Jenkins stays `localhost:8081`.

### [DESIGN] D4 — Mission Control's read access outside `payments` ships separately

The PDF gives it "read everything in payments/monitoring/tracing/logging". The pipeline applies a
service's manifest with `kubectl -n payments`, and kubectl refuses objects whose namespace
differs. So `k8s/mission-control.yaml` holds everything in `payments` (ServiceAccount, the write
Role, PVC, Deployment, Service, ServiceMonitor — the pipeline's door) and
`k8s/mission-control-rbac.yaml` the three read-only Roles elsewhere, applied once by `210`.
Permissions outside a service's namespace are a platform decision, not a deploy-time one.

### [DESIGN] D5 — The "third receiver" is a third webhook on the existing receiver

Same reason as Day 12's fan-out to the remediator: a second route could drift from the first
(one of them gets a new matcher, the other does not, and the feed silently shows less than the
tickets). One route, one receiver, three webhooks: bot, remediator, mission control. Applied
through Terraform (`k8s/kps-values.yaml`) — after mission control is deployed, or Alertmanager
retries a URL that does not exist yet.

### [DESIGN] D6 — Who may approve: people, by entrance; the same person may request and approve

`HUMAN_ENTRANCES = button | command | api`. A request with `X-Entrance: copilot` or `mcp` can
create a tier-2 approval and is refused (403, and an audit row saying so) if it tries to approve
or decline one. With one operator, the requester and the approver are the same person; the audit
row records both names and the entrance each came through, so a two-person rule is one `if`
away when there are two people.

### [DESIGN] D7 — The event stream accepts its token in the URL; nothing else does

The browser's `EventSource` cannot send an `Authorization` header. `GET /api/events` alone also
accepts `?access_token=`. Tokens in URLs end up in access logs and browser history: uvicorn runs
with `--no-access-log`, the feed is read-only, and it is the only route with the exception.

### [DESIGN] D8 — `/hooks/alertmanager` has no bearer token and can never act

Alertmanager can send credentials, but the hook is display-only: it publishes to the feed and
nothing on that code path reaches the catalog. It is reachable only inside the cluster
(ClusterIP, no NodePort). The worst a forged notification can do is draw a false alert on the
screen — which is also what a real one looks like until you open the incident.

### [NOTE] N6 — `/api/chat`, `/api/eval`, `/api/kpis` answer 501 until Days 23–24

They exist in the route table because the UI will call them; they say "not built yet — Day N"
instead of returning an empty 200 that a screen could mistake for "no data".

### [BUG] B6 — The webhook apply "failed" on an etcd timeout — the change itself had landed

First `tf.sh apply` for the third webhook (14:45 local): `Error upgrading chart`. Helm's history
had the reason Terraform's one-line error did not: *post-upgrade hook … admission-webhooks/job-patch/
clusterrolebinding.yaml failed: etcdserver: request timed out.* A Helm upgrade applies the chart's
objects **first** and runs its hooks **after**, so the Alertmanager config was already updated; what
failed was the chart's certificate-patch hook, because etcd could not commit one write. The node was
in a storm at the time — load **69** (5 min), etcd **2,482** "took too long" warnings in the hour,
the controller-manager and scheduler on their third restart since B4's longer leases, the Prometheus
operator on its twelfth. Twelve minutes later, load under 4: the same apply, **45 s**, revision 4
`deployed`, plan clean. **Lessons:** read `helm history` (the full `description`) before touching a
failed release; a hook failure is not a failed change; and retry on a calm node, never during the
storm. What starts the storms is not yet pinned (`vmstat` twelve minutes later: 95 % idle, no I/O
wait — they come and go); the etcd warning count per minute is now part of the diagnosis kit:
`kubectl -n kube-system logs etcd-bhn-sim-control-plane --since=1h | grep 'took too long' | grep -o '"ts":"[^"]*' | cut -c18-22 | sort | uniq -c`.

### [NOTE] N7 — Alertmanager hides webhook URLs; three checks have been grepping the wrong line since Day 8

`/api/v2/status` showed no `mission-control` after a successful apply. Since Alertmanager 0.25 a
webhook `url` is a secret type and the status API prints it as `url: <secret>`. The Day 8 and Day
12 checks (`grep -q incident-bot`, `grep -q remediator`) kept passing only because those words are
also in the route's *matcher* (`service =~ "…|incident-bot|remediator|…"`) — they proved a regex, not
a webhook. `218` now reads the URL from the operator-generated config Secret (what `81`/`121` already
did when they set routes up), and proves delivery separately with `mc_alertmanager_webhooks_total`.
A check that passes for the wrong reason is how a missing webhook would have gone unnoticed.


### [NOTE] N8 — The first drill run reverted before the alert could exist, and the audit hid true from false

Fault approved 20:19:11Z, revert requested 20:21:27Z — 2 m 16 s. `ActivationHighErrorRate` needs the
pod restart (~20 s), its 2 m `rate()` window to cross 10 %, `for: 2m`, then Alertmanager's 15 s
`group_wait`: about four minutes before the feed can show anything. My "~2–3 min" in `DAY21.md` was
the rule's `for:` alone. Same run: `tools/mc.py audit` cut the params at 60 characters, which removed
`"value": "true"` / `"value": "false"` — the one field that says whether a row broke production or
fixed it. The audit list now prints `k=v`, uncut.
