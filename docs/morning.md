# Morning — bringing the platform back after sleep / reboot

Ten minutes, in this order. Every step is idempotent; run it again if in doubt.
What breaks overnight, from two weeks of evidence: the WSL localhost relay (ports stop
answering after the laptop sleeps), Splunk's container IP (moves on every Docker restart),
port-forwards and load generators (never survive), and — only if a pod was *replaced* —
Grafana's service-account tokens.

## 0 · Windows (PowerShell, as yourself)

```powershell
wsl --shutdown
```

Then start **Docker Desktop** and wait for the whale to settle (~1 min). The shutdown is not
optional after a sleep: the symptom of skipping it is `TimeoutError` from the load
generators and `helm`/`kubectl` "cluster unreachable" while `docker ps` looks fine.

Since Day 15 the VM is shaped by `C:\Users\bkala\.wslconfig` (8 CPUs, 10 GB, 4 GB swap,
`autoMemoryReclaim=gradual`), and DNS is **systemd-resolved with its own upstream**
(`/etc/systemd/resolved.conf.d/lab.conf` → 1.1.1.1 / 8.8.8.8) instead of WSL's relay
`10.255.255.254`, which stalls every Go program — helm, terraform, the AWS provider — while
curl works. `/etc/wsl.conf` has `generateResolvConf=false` so WSL leaves the file to
resolved. `up.sh` checks that a name actually resolves; if it warns:

```bash
sudo systemctl restart systemd-resolved && resolvectl query github.com | head -1
```

(and if `lab.conf` is gone: recreate it with `[Resolve]` / `DNS=1.1.1.1 8.8.8.8`, then restart).

## 1 · Terminal 1 — the platform

```bash
cd ~/bhn-sim && ./scripts/up.sh
```

Read it top to bottom. It starts the containers, re-exports the kubeconfig, waits for the
node, removes tombstoned pods, resets the incident knobs, checks the ticket layer (bot,
remediator, fan-out, open incidents, **the three collectors**), the log pipeline, and —
since Day 13 — runs `terraform plan` against the platform layer and checks the Jenkins image.

What each warning means and what to do:

| Warning | Do |
|---|---|
| `fluent-bit ships to X but Splunk is at Y` / plan shows **DRIFT: fluent_bit** | Splunk moved. `./infra/local/tf.sh plan` (one change: the `Host` line) → `./infra/local/tf.sh apply`. Terraform renders the new IP itself; nothing else to edit. |
| `enrichment: secret says … but Splunk is at …` | `./scripts/100-enrich-config.sh` (rewrites the bot's Splunk URL and re-mints its Grafana token) |
| `collectors: … deploys=FAIL` | Grafana's pod was replaced and forgot its service accounts: `./scripts/100-enrich-config.sh && ./scripts/120-remediator-config.sh` |
| `collectors: … logs=FAIL` | Splunk still booting (`docker logs splunk \| tail -3` — wait for *Ansible playbook complete*) or the enrichment secret has the old IP (row above) |
| `N open incident(s)` | `python3 tools/inc.py list open` — overnight tickets are real; read them before touching anything (Day 14 wants them) |
| `remediator in DRY_RUN` | `kubectl -n payments set env deploy/remediator DRY_RUN=false` — should not happen unless you set it |
| `plan failed` | usually `splunk not running` (start it) or the cluster still coming up — re-run `up.sh` in a minute |
| VM sluggish, `kubectl` slow or resetting | `uptime` (load average) and `docker stats --no-stream`; anything over the core count is the cause. Splunk is capped at 1.5 CPUs by `up.sh`; if the node itself is the hog, wait — it is re-scheduling pods |
| `Jenkins image lacks terraform` | `./scripts/133-drift-check-job.sh` rebuilds it (asks for the Jenkins password) |
| `not healthy:` pod list | `Error` pods from old settlement drills are fine; anything `CrashLoopBackOff` is not — `kubectl -n <ns> describe pod <name>` |

Then the two proofs that everything downstream depends on:

```bash
./scripts/100-enrich-config.sh --check      # three collectors ok
./infra/local/tf.sh plan -detailed-exitcode >/dev/null; echo "exit $?"    # 0
```

## 2 · Terminal 2 and 3 — traffic

```bash
./scripts/12-loadgen.sh            # Terminal 2 — activation
./scripts/33-loadgen-egift.sh      # Terminal 3 — egift
```

Give them a minute before believing any dashboard: every rate panel is a 2–5 minute window.

## 3 · Terminal 4 — Grafana

```bash
./scripts/06-grafana.sh            # port-forward on :3000, prints admin / <password>
```

The password comes from `secret/grafana-admin` now (Day 13). Open **Platform Overview**
first. If a dashboard is missing, `./scripts/09-grafana-dashboards.sh`.

## 4 · Terminal 1 — the last look before starting the day

```bash
python3 tools/inc.py list open       # expect: nothing
python3 tools/rem.py pending         # expect: nothing
python3 tools/kpis.py | tail -5      # the numbers Day 14 will review
kubectl -n logging get pods          # Fluent Bit RESTARTS — should still be 0 (Day 13's fix, verification pending)
./scripts/171-newrelic-up.sh --status   # Day 17+: agents Running, remote-write succeeded climbing, failed 0
./scripts/172-kb.sh --check             # Day 17+: the running bot sees kb/ (7 entries)
```

## 5 · Week 3 — the cloud side (Day 15 onward)

```bash
aws sso login --profile lab             # sessions expire overnight; this is normal
./scripts/155-aws-verify-destroyed.sh   # anything billing that should not be? (EIPs are the usual leftover)
./scripts/154-aws-cost.sh --row <day>   # yesterday's bill -> the row for docs/aws-costs.md
./scripts/152-aws-vpc.sh status         # what exists right now
./scripts/160-eks.sh status             # Day 16+: cluster, nodes, add-ons, load balancers (should be "not found" after a teardown)
```

Paused last night with `152 destroy`? `./scripts/152-aws-vpc.sh plan` then `apply` — five minutes.
Cluster day? `160 plan/apply` (~15 min) → `162 plan/apply` (~5) → `163` (~3): a warm start in
about twenty-five minutes from network-up. Nothing on kind changes: the same scripts run against
EKS with `KUBE_CONTEXT=aws-lab`, and without it they still mean kind.

## When it is not this simple

| Symptom | Cause / fix |
|---|---|
| `up.sh` dies at *Docker daemon unreachable* | Docker Desktop not up yet; wait, re-run |
| `terraform`/`helm` time out "awaiting headers" or "TLS handshake timeout" while `curl` works | the WSL DNS relay is back in `/etc/resolv.conf` — the one-liner in step 0 |
| `kubectl` hangs (not refused) and load average is far above the CPU count | the VM thrashed on memory; `cat /proc/pressure/memory`; if `docker exec bhn-sim-control-plane true` also hangs: `docker kill bhn-sim-control-plane && docker start bhn-sim-control-plane`, 60 s, `up.sh` |
| node never Ready | `docker restart bhn-sim-control-plane; sleep 30; ./scripts/up.sh` |
| `kubectl` works, `helm` says *cluster unreachable* | you skipped `wsl --shutdown` |
| Jenkins on :8081 not answering | `docker start jenkins` (up.sh does it) then ~60 s |
| Splunk UI on :8000 not answering | still booting; 2–3 min after `docker start splunk` |
| load generator `TimeoutError` after it ran fine for a while | the relay again: `wsl --shutdown` from PowerShell, then from step 1 |
| `aws` says token expired / no session | `aws sso login --profile lab` |
| a settlement ticket opened overnight | look at the timeline before anything: the remediator may already have re-run it (tier 1) |
