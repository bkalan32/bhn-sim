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
```

## When it is not this simple

| Symptom | Cause / fix |
|---|---|
| `up.sh` dies at *Docker daemon unreachable* | Docker Desktop not up yet; wait, re-run |
| node never Ready | `docker restart bhn-sim-control-plane; sleep 30; ./scripts/up.sh` |
| `kubectl` works, `helm` says *cluster unreachable* | you skipped `wsl --shutdown` |
| Jenkins on :8081 not answering | `docker start jenkins` (up.sh does it) then ~60 s |
| Splunk UI on :8000 not answering | still booting; 2–3 min after `docker start splunk` |
| load generator `TimeoutError` after it ran fine for a while | the relay again: `wsl --shutdown` from PowerShell, then from step 1 |
| a settlement ticket opened overnight | look at the timeline before anything: the remediator may already have re-run it (tier 1) |
