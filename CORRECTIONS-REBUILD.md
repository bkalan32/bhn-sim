# The rebuild — Corrections Log

Not a day of the series: the lab rebuilt from git on **23 Sep 2026**, after Docker Desktop was
wiped (containers, networks and the kind cluster gone; images and the `jenkins_home` volume
survived). The README's runbook said the lab could be rebuilt from this repository. It could —
after nine fixes, found in the order below. The tested sequence is now `docs/rebuild.md`.

---

## [BUG] B1 — The platform apply needs three Secrets that need namespaces that Terraform owns

`helm_release.kps` mounts `secret/grafana-admin` (Day 13 B10) and Prometheus's remote write
mounts `secret/newrelic-license` (Day 17); Fluent Bit reads `secret/splunk-hec` (Day 13 B9).
None are Terraform's — that is the point of them — and a release with `wait = true` whose pods
cannot mount a Secret fails **slowly**: fifteen minutes of `ContainerCreating`, then a timeout.
The Secrets need namespaces, and Terraform owns the namespaces (Day 13, one owner). **Order:**
targeted apply of the five namespaces → the three Secrets by their scripts → the full apply.
On the day, a quick `kubectl get secret` caught the missing New Relic key before the apply —
a pasted 64-character string had been stored instead of the 40-character license (403 at the
script's own test POST, which is why that test exists).

## [BUG] B2 — On an empty cluster the plan cannot render kube-prometheus-stack (Day 16 B11, on kind)

`Error performing dry run install … no matches for kind "Prometheus" in version
"monitoring.coreos.com/v1" — ensure CRDs are installed first.` `experiments.manifest = true`
(Day 13 B8) makes every plan a server-side dry run, and a dry run installs nothing — so the
Operator's CRDs do not exist while kps's manifests are validated. EKS hit this on Day 16 and
got a fix (`162 plan` step 3); kind never did, because its CRDs predated Terraform (the release
was *imported* on Day 13). The plan showed 8 to add, not 10: `pushgateway` and `newrelic`
depend on kps and were never considered. **Fix:** the ten `crd-*.yaml` from the **same pinned
chart** (88.6.2), `kubectl create` (not `apply`: the `prometheuses` CRD exceeds the client-side
annotation limit); Helm then skips its own copy. Now step 3 of `scripts/135-platform-from-zero.sh`.

## [BUG] B3 — The first install taints kps and the New Relic bundle (Day 16 D6, on kind)

Ten `Provider produced inconsistent result after apply` on kps (the Operator's admission
webhook stamps every PrometheusRule with `prometheus-operator-validated: "true"`; the dry-run
render has no such annotation), then six on `newrelic`. The releases were healthy — all six
monitoring pods Running in three minutes — but Terraform taints a resource whose apply errored,
and a tainted release is **replaced** on the next apply. `untaint`, re-apply (kps: in-place, the
state absorbs the post-webhook manifest; newrelic: nothing to do), and the proof is the plan
after: `exit 0`, `No changes`. The apply-time error names the resource as *"When applying
changes to helm_release.X"*, not *"with helm_release.X"* like a plan error — the first grep for
it found nothing. `135` step 4 untaints only when **every** error is this one.

## [BUG] B4 — Scripts that ask Docker a question wait forever when Docker does not answer

`tf.sh plan` sat silent for **22 minutes**: its first action is `docker inspect splunk` (for the
IP), stderr discarded, and the Docker CLI in WSL was not answering — while `kubectl` worked fine
(the node was already running and does not need the daemon). A Docker Desktop restart cleared
it; the WSL-integration settings page hung on *"Fetching installed WSL 2 distros"*; a Windows
reboot fixed it. It happened twice more that afternoon, both times with `up.sh` stuck at
`==> Docker` on `docker info`. Investigated: every CLI plugin answers its metadata call in under
a second; the daemon's `/version` and `/info` both answered in < 0.5 s moments later. All three
hangs coincided with the VM at load 45–66 (B7, D1), so the likeliest reading is *queued behind
the storm*, not broken — but the root cause was not caught in the act. **Fix, whatever the
cause:** a dependency you do not own gets a bounded question and a legible failure.
`lib.sh`'s `require_docker` and `up.sh` now ask `timeout 15 docker version --format
'{{.Server.Version}}'` (one round trip, no plugins, no daemon-side gathering) instead of
`docker info`; `tf.sh`'s `docker inspect` has a 15 s limit and says which of three things is
wrong. Twenty-two minutes of nothing is the worst error message there is.

## [BUG] B5 — The load generator blamed the cluster's port mapping for a service with no pods

`12-loadgen.sh`: *"localhost:30080 not reachable — your kind cluster has no host mapping for
it"*, then a fallback to a port-forward on :8000 — which **Splunk's web UI** holds (and `ss`
shows no owner for, since Docker Desktop's proxy publishes it). The mapping was fine; the
NodePort Service had no endpoints because activation was not deployed yet, and a Service with
no endpoints refuses connections exactly like a missing mapping. The script now asks for the
Service's endpoints first and says *deploy activation first* if there are none. (And `kill
$(lsof -t -i:8000)` failing on an empty list was, for once, a lucky bug.)

## [BUG] B6 — A first deploy cannot pass Verify, and then cannot roll back

Build #41 (activation): deployed, rolled out in 11 s, then Verify — *"No traffic reached
activation after deploy — treating as failed"* — correct: no load generator could run before
there were pods (B5), and the ServiceMonitor was created by that same apply (Prometheus needs
30–60 s to start scraping a new one). Then the post block ran `rollout undo`: *"no rollout history
found"*, a stack trace, and **activation:41 left running** — by luck, the right outcome. **Fix:**
the Jenkinsfile's rollback branches now check for a previous image; on a first deploy they say
*"FIRST DEPLOY … no previous revision … LEFT RUNNING"* with the two ways forward, instead of
dying. **Procedure:** the first build of a traffic-verified service uses `SKIP_VERIFY`, the load
generator starts, and the second build is the verified one (#42, green). SKIP_VERIFY exists for
the Day 12 drill; its big warning in the console is honest here too — there is nothing to verify
against yet.

## [BUG] B7 — The OTel collector was killed by its own liveness probe, seven times in 70 minutes

Load average **66 on 8 CPUs**, `kube-controller-manager` and `kube-scheduler` restarting (they
lose their leader leases when the node is too starved to renew them — the cluster stopping
managing itself), and one workload unhealthy: `otel-opentelemetry-collector`, `0/1`, 7 restarts,
`Error exit=2`. Its log showed a clean start every time with the health endpoint open ~2 s in;
the events showed why it died: *"Liveness probe failed … context deadline exceeded"* then
*"Container … failed liveness probe, will be restarted"*. The chart's defaults give it one
second to answer, from almost the moment it starts; each restart spent more CPU on a starved
node, which made the next probe fail — a feedback loop. **Day 13's Fluent Bit bug, second
service.** Fix in `k8s/otel-values.yaml` (Terraform, one in-place change): liveness 30 s delay /
5 s timeout / 6 failures, readiness 10 s / 5 s / 3; CPU limit 500m → 1 (a Go process loading
config on half a core is slow in exactly the moment the probe watches). New pod: 0 restarts;
the 1-minute load fell from 66 to 0.93.

## [BUG] B8 — `up.sh` reported "DRIFT: 0 release(s) differ" and then named six

It counted only `will be updated`; on the rebuild every release was `will be created`. It now
counts created / updated / destroyed / replaced and says *resource(s)*.

## [BUG] B9 — The rebuilt platform paged about services that did not exist yet

Two tickets nobody looked at until the Day 21 import listed them: `IncidentBotDown` (critical,
opened 16:38:20Z, 2.5 min) and `RemediatorDown` (warning, 16:38:25Z, 4.6 min). The first reading —
the config scripts' restarts, stretched by the CPU storm — was **wrong**, and the ReplicaSets'
creation times said so: the bot's *first* ReplicaSet is 16:37:45Z (its first Jenkins deploy), the
remediator's first is 16:39:47Z — *after* its ticket opened. `k8s/alerts.yaml` had been applied
(step 3) before any service existed, so every "X is down" rule was firing against services that
were never up, and Alertmanager was retrying the webhook into a bot that did not exist. The bot's
first act, 35 s into its life, was to open a ticket about its own absence; the remediator's
ticket closed when its first deploy (plus `120`'s restart at 16:42:11Z) was Ready. **Fix:**
`docs/rebuild.md` applies the rules *after* the five services. The general rule: on a bring-up,
alerts go live last — or behind a silence — or the first page of a new platform is about
itself. (Mission Control's `silence_alert` action, Day 21 Step 3, is the other half.)

---

## [BUG] B10 — A power cut reshuffled the container IPs, and three things broke without a word

23 Sep, 16:44 local: the PC lost power. Everything came back — pods Running, etcd clean, `up.sh`
green enough — and five hours later a drill showed the incident page's log histogram empty
("no error-status events") while activation failed seven requests a second. Fluent Bit had been
`0/1` since the reboot, retrying and then dropping every chunk: it was sending to 172.19.0.3.
Docker gives addresses on the kind network in **start order**; before the power cut the order was
node .2, splunk .3, jenkins .4, after it jenkins .2, node .3, splunk .4. Three consumers held the
old addresses: Fluent Bit's Splunk host (Terraform), the bot's `SPLUNK_URL` (`enrich-config`) and
Mission Control's `JENKINS_URL` — the last now pointing at Splunk. The code knew: `tf.sh`'s own
comment says the IP "moves on every Docker restart", and `up.sh` warns when `SPLUNK_URL` drifts.
Knowing and warning is not fixing. **Fix:** `scripts/137-pin-container-ips.sh` gives Splunk and
Jenkins fixed addresses (x.y.255.10 / .11, far from Docker's own allocation) in place — stop,
reconnect with `--ip`, start; data, trial and jobs untouched — and `21-splunk-up.sh` /
`50-jenkins-rebuild.sh` create them pinned. `210-mc-config.sh` now restarts Mission Control after
repairing its Jenkins URL (it updated the Secret and left the pod on the old address), and
`100-enrich-config.sh` restarts it after re-minting the Grafana token it also reads. The lesson
for the platform's own alerting — a log pipeline down for five hours paged nobody — is a Day 24
item: `FluentBitNotShipping` (output errors > 0 for 10 m, or no events in Splunk for 10 m).

## [BUG] B11 — Every Splunk restart turned HEC's SSL back on; Terraform kept telling Fluent Bit "Off"

The second half of B10's silent five hours. With Splunk at its pinned address, plain HTTP to
8088 still got nothing — from Fluent Bit, from WSL, even from inside the container — while
HTTPS answered 200. The `splunk/splunk` image re-runs its Ansible setup on **every container
start** ("Setup global HEC"), and its default is HEC over SSL; the rebuild's "SSL off" was a
click in the web UI that lived only until the first restart. The power cut was the first
restart. `22-fluent-bit.sh` had always probed both schemes — once, on day 3 — and wrote the answer
into the rendered values file; `tf.sh` read that file forever after. A fact about a running
system was stored as if it were configuration. **Fix:** `tf.sh` asks HEC on every run (https,
then http; localhost from WSL, the container IP from Jenkins) and falls back to the rendered
file only if Splunk does not answer, saying so. Fluent Bit therefore runs with TLS On and
TLS.Verify Off (Splunk's certificate is self-signed — the same trade the bot has made on 8089
since Day 10), and the HEC token now crosses the kind network encrypted, which it should have
all along.

## [DESIGN] D1 — New Relic's cluster agents are off; the remote write stays

The storm came back after B7 (Docker Desktop: 3393 % of 800 % CPU, 9.40 of 9.48 GB), and the
heaviest single process on the node during the first one was `nri-kubelet` at 73 % of a CPU —
for a cluster view Grafana and Splunk already give us. What Day 17 earned is the business
metrics in New Relic by **remote write** from our own Prometheus, with a keep-list as the cost
control: no agent involved. `newrelic-infrastructure`, `nri-kube-events` and `newrelic-logging`
are `enabled: false` in `k8s/newrelic-values.yaml` (Terraform, in-place); the release, namespace
and Secret stay, so bringing them back is three `true`s. Proof the part we kept still works:
`sum(rate(prometheus_remote_storage_samples_total[5m]))` = **14.1 samples/s** after the agents
were gone. The lab runs at the edge of 8 CPUs / 9.7 GB, and Mission Control is about to add a
service — headroom is a feature.

## [DESIGN] D2 — `scripts/135-platform-from-zero.sh` and `docs/rebuild.md`

The README's "Rebuild from zero" replays Days 1–15 in order; since Day 6 (Jenkins owns the
services) and Day 13 (Terraform owns the platform) that replay no longer produces today's lab —
`05-install-monitoring.sh` would install kps outside Terraform, for one. `docs/rebuild.md` is the
tested order; `135` encodes B1–B3 so the next rebuild does not rediscover them. The README's
runbook now opens with a pointer to it, and its rebuild estimate is the measured one.

---

## [NOTE] N1 — What could not come back

The incident-bot's live records (Day 8: JSON on a local-path PVC) lived inside the kind node's
container and died with it; the bot starts an empty store. `incidents/INC-*.md` are the
permanent record and are intact. Day 21's first chore (SQLite on a PVC) is the same lesson with
a better database — and a PVC on kind is still inside the node: the durable copy of anything is
the one in git or off the laptop.

## [NOTE] N2 — C: is 99 % full (4.6 GB free)

Both WSL's and Docker Desktop's disk images live on C: and only grow; when C: fills, both VMs
stop writing at once. Not a lab change — a Windows cleanup (old Docker projects, Downloads,
temp) — and `docs/rebuild.md` step 0 now checks it.

## [NOTE] N3 — Secrets that left the terminal

Two secrets were pasted outside a terminal prompt during the rebuild (a HEC token into a chat,
a New Relic license key visible in a console screenshot). Both are lab-local in effect, but the
rule is the rule: rotate them (Splunk HEC page → new token → `22-fluent-bit.sh <new>`; New Relic
API keys → new INGEST key → `170-newrelic-secret.sh`), because each script run *is* the whole
rotation — nothing but the Secret holds the value.

## [NOTE] N4 — Smaller things, recorded so they are not rediscovered

- The Jenkins admin password lives only as a hash in `jenkins_home`; if it is lost, the reset
  is a one-shot `init.groovy.d/reset.groovy` (`HudsonPrivateSecurityRealm.Details.fromPlainPassword`),
  removed after the restart that reads it — it holds the password in plain text. On the day,
  `cat initialAdminPassword | clip.exe && echo copied` printed "copied" and the login still
  failed: a pipe's exit status is the *last* command's, and `clip.exe` succeeds on empty input.
- `kind/bhn-sim-cluster.yaml` still does not pin the node image; `kind` v0.x gave v1.37.0 again.
- Splunk is a new container: the 60-day trial clock restarted.
- The API key's model list shows `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5`; the bot
  still drafts with `claude-sonnet-4-5` (not listed, still served). Mission Control's copilot
  model is chosen on Day 21 and written into `docs/ai-eval.md`, not taken from the PDF.
- `up.sh`'s `docker info` probe (B4) is the same one `00-preflight.sh` and `02-verify.sh` use;
  those run once on a new machine and were left as they are.

---

## Verified as correct

The README's claim that the lab is rebuildable from git plus typed secrets (true, in the right
order); `jenkins_home` as a volume (three jobs, 40 builds of history, plugins, all survived);
Terraform owning the platform (the drift check's `No changes` is the definition of rebuilt);
secrets outside state (none of the three had to be recovered from anywhere but a person);
the pipeline as the only door for services (every service came back through it, with a
change-cause and a Grafana annotation); `up.sh --check` as the single verdict.
