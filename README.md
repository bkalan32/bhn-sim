# bhn-sim — local incident response lab

A fake production payments platform built to be broken on purpose.
Card activation API, eGift issuance, a nightly settlement job, flaky third-party mocks —
wrapped in metrics, logs, traces, dashboards, alerts, ticketing and an AI incident assistant.

**Host:** Windows + WSL2 Ubuntu · **Cluster:** kind · **Context:** `kind-bhn-sim`

> The test for this runbook: *if my laptop died tonight, could I rebuild from this file in
> 30 minutes?* Prove it with `scripts/99-teardown.sh` and then rebuild.

---

## Rebuild from zero

```powershell
# PowerShell (admin), once
wsl --install -d Ubuntu-24.04          # then reboot
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
# Docker Desktop > Settings > Resources > WSL Integration > toggle Ubuntu ON
```

```bash
# Ubuntu
cp -r /mnt/c/Users/bkala/Downloads/bhn-sim/. ~/bhn-sim/  # the /. copies .gitignore too
cd ~/bhn-sim
./scripts/00-preflight.sh          # check the machine can host this
./scripts/01-install-tools.sh      # kubectl kind helm terraform python git
./scripts/02-verify.sh             # -> checkpoints/day1-versions.txt
./scripts/03-cluster-up.sh         # kind cluster "bhn-sim"
./scripts/04-smoke-test.sh         # nginx up, curl, down
./scripts/05-install-monitoring.sh # prometheus + grafana + alertmanager
./scripts/07-jenkins.sh            # CI container on :8081
./scripts/09-grafana-dashboards.sh # dashboards/*.json -> ConfigMaps (survive restarts; re-run after editing JSON)
./scripts/08-checkpoint.sh         # did Day 1 actually pass?

# Day 2
./scripts/10-build-activation.sh   # venv, image, kind load
./scripts/11-deploy-activation.sh  # namespace, deployment, service, servicemonitor
./scripts/13-verify-scrape.sh      # is Prometheus scraping it?
./scripts/12-loadgen.sh            # traffic (leave running)
./scripts/14-mini-incident.sh      # 30% errors, then recover
./scripts/18-checkpoint-day2.sh    # did Day 2 actually pass?

# Day 3
./scripts/20-upgrade-activation.sh # v0.2 with JSON logs
./scripts/21-splunk-up.sh          # Splunk container (starts the 60-day clock)
./scripts/22-fluent-bit.sh <TOKEN> # ship payments logs to Splunk HEC
./scripts/23-alerts.sh             # PrometheusRule + verify loaded
./scripts/24-incident-fraud.sh     # FRAUD_SVC_DOWN drill, end to end
./scripts/28-checkpoint-day3.sh    # did Day 3 actually pass?

# Day 4
./scripts/30-install-tracing.sh    # Tempo + OTel Collector + Grafana datasource (as code)
./scripts/31-instrument-activation.sh  # activation v0.3, trace_id in logs
./scripts/32-build-egift.sh        # second service
./scripts/33-loadgen-egift.sh      # corporate orders (leave running)
./scripts/34-verify-traces.sh      # waterfall + both-services assertion
./scripts/35-experiment-latency.sh A|B  # same dashboard, different culprit
./scripts/38-checkpoint-day4.sh

# Day 5
./scripts/40-slo-rules.sh          # recording rules + burn-rate alerts
./scripts/41-burn-budget.sh        # ERROR_RATE=0.50, watch BurnFast fire & resolve
./scripts/42-install-pushgateway.sh
./scripts/43-build-settlement.sh   # CronJob every 5 min, runs one now
./scripts/44-settlement-failure.sh crash|silent|none|lenient
./scripts/48-checkpoint-day5.sh

# Day 6
./scripts/50-jenkins-rebuild.sh    # Jenkins + docker/kubectl/kind, on the kind network
./scripts/51-test-local.sh         # pytest, as the pipeline runs it
./scripts/52-jenkins-job.sh        # create deploy-service via API (or click it)
./scripts/53-bad-deploy.sh apply|revert
./scripts/54-manual-rollback.sh    # timed drill
./scripts/58-checkpoint-day6.sh

# Day 7
./scripts/60-health-scores.sh      # load + read the four scores
./scripts/61-score-sanity.sh       # prove the score moves (10% errors)
./scripts/62-fail-fast-drill.sh    # INC-0001 re-run against v0.4, before/after
./scripts/68-checkpoint-day7.sh

# Day 8
./scripts/80-build-incident-bot.sh # tests, image, PVC, deploy, synthetic webhook smoke test
./scripts/81-alertmanager-route.sh # new rules + helm upgrade (pinned) + prove Alertmanager reloaded
./scripts/82-incident-drill.sh     # fault -> alert -> webhook -> incident opens -> auto-resolves
./scripts/83-settlement-strict.sh  # INC-0005 fix verified in all three modes
./scripts/84-test-catches-bug.sh   # INC-0006 fix verified: velocity bug dies on a branch in seconds
./scripts/88-checkpoint-day8.sh

# Day 9
./scripts/90-ai-secret.sh          # API key -> Secret (verified first); --check / --remove / --ollama URL
./scripts/91-ai-smoke.sh           # synthetic incident, both drafts, cost/latency, 1 minute
./scripts/92-ai-drill.sh           # fraud outage with YOU as scribe; drafts at open and close
./scripts/93-ai-resilience.sh      # provider off -> incident still records -> provider on
./scripts/98-checkpoint-day9.sh

# Day 10
./scripts/100-enrich-config.sh     # Grafana service-account token + Splunk REST creds -> secret; tests the 3 collectors
./scripts/102-drill-a.sh           # dependency outage: ticket arrives with context + diagnosis (INC-0009)
./scripts/103-drill-b.sh apply|revert  # bad deploy via pipeline, same alert, different diagnosis (INC-0010)
python3 tools/kpis.py              # the KPI table for docs/ops-kpis.md
./scripts/108-checkpoint-day10.sh

# Any time, after a Docker restart / reboot
./scripts/up.sh                    # containers, kubeconfig, tombstones, knob reset, front doors
./scripts/up.sh --check            # read-only
```

---

## Daily drivers

| What | Command / URL |
|---|---|
| Cluster context | `kubectl config use-context kind-bhn-sim` |
| Node health | `kubectl get nodes` |
| Monitoring pods | `kubectl get pods -n monitoring` |
| Grafana | `./scripts/06-grafana.sh` → http://localhost:3000 (admin) — **open Platform Overview first** |
| Dashboards gone after a restart | `./scripts/09-grafana-dashboards.sh` (they are ConfigMaps now; UI imports are not persistent) |
| Prometheus | `./scripts/13-verify-scrape.sh` (or look the name up: `kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus`) |
| Alertmanager | `kubectl get svc -n monitoring -l app.kubernetes.io/name=alertmanager` then port-forward it on 9093 |
| Jenkins | http://localhost:8081 |
| Splunk | http://localhost:8000 — admin / Changeme123! |
| Tempo (traces) | Grafana → Explore → Tempo → Search by Service Name |
| Trace → logs | copy trace ID → Splunk `index=main app.trace_id=<id>` |
| eGift API | http://localhost:30443/orders |
| Service logs | `kubectl logs -n payments -l app=activation --tail=20 \| python3 tools/logfmt.py` |
| **Incidents** | `python3 tools/inc.py list` · `timeline <id>` · `show <id>` · `note <id> "text"` |
| **AI drafts** | `python3 tools/inc.py drafts <id>` · `draft <id> open\|resolved\|hypothesis` (re-run) · `ai` (which provider) |
| **Enrichment** | `python3 tools/inc.py context <id>` · `hypothesis <id>` · `enrich <id>` · `enrich-test [service]` · `./scripts/100-enrich-config.sh --check` |
| Alertmanager live config | `kubectl get --raw /api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-alertmanager:9093/proxy/api/v2/status` |
| **Recover after restart** | `./scripts/up.sh` |
| Stop everything | `wsl --shutdown` (PowerShell) |

---

## Installed tools

Run `./scripts/02-verify.sh` to regenerate `checkpoints/day1-versions.txt`.

| Tool | Where it lives | Install source |
|---|---|---|
| Docker Desktop | Windows | `winget install -e --id Docker.DockerDesktop` |
| Cursor | Windows | `winget install -e --id Anysphere.Cursor` |
| kubectl | Ubuntu | apt · pkgs.k8s.io |
| kind v0.33.0 | Ubuntu | binary · kind.sigs.k8s.io |
| helm | Ubuntu | get.helm.sh |
| terraform | Ubuntu | apt · apt.releases.hashicorp.com |
| python 3.12 | Ubuntu | system python (Ubuntu 24.04) |
| git | Ubuntu | apt |

---

## Hosted accounts

| Service | URL | Status | Notes |
|---|---|---|---|
| GitHub | https://github.com | ☐ | private repo `bhn-sim` |
| ServiceNow PDI | https://developer.servicenow.com | ☐ | **request Day 1** — waitlisted, and PDIs hibernate |
| New Relic | https://one.newrelic.com | ☐ | free forever · 100 GB/mo · 1 full user |
| Splunk | https://splunk.com | ☐ | account Day 1, **start the container Day 3** (60-day trial clock) |
| AWS | https://aws.amazon.com | ☐ | **create around Day 14**, not Day 1 (6-month credit window) |

---

## Ports

| Port | Service |
|---|---|
| 3000 | Grafana (port-forward) |
| 8080 | smoke test / scratch |
| 8000 | Splunk web UI |
| 8081 | Jenkins |
| 8088 | Splunk HEC |
| 9090 | Prometheus (port-forward) |
| 9093 | Alertmanager (port-forward) |
| 30080 | activation NodePort |
| 30443 | egift NodePort (not HTTPS — the second mapped slot) |
| 8020 | incident-bot (in-cluster; reach it via `tools/inc.py` / API proxy) |
| 3200 | Tempo HTTP (in-cluster; port-forward if needed) |
| 4317 / 4318 | OTLP gRPC / HTTP |

---

## Log

| Day | Topic | Done |
|---|---|---|
| 1 | Incident response lab | ☐ |
| 2 | First service + dashboard | ☐ |
| 3 | Logs, Splunk, first alert | ☐ |
| 4 | Second service + tracing | ☐ |
| 5 | SLOs and silent failure | ☐ |
| 6 | CI/CD, bad deploy, rollback | ☐ |
| 7 | Health score and first fix | ☐ |
| 8 | Alert routing + incident bot | ☐ |
| 9 | AI summaries and comms | ☐ |
| 10 | Context-enriched alerts, first AI diagnosis | ☐ |

---

## Deploy and rollback (Day 6) — read this at 3 AM

**Deploy:** http://localhost:8081/job/deploy-service → *Build with Parameters* → `SERVICE`, `CHANGE_CAUSE`.
Stages: Test → Build (`<service>:<build#>`) → Deploy (apply manifest, record cause, Grafana line) → Verify (2 min, error rate vs `max(10%, 3×baseline)`) → auto-rollback on Verify failure.

**What's running / what changed:**
```bash
kubectl -n payments rollout history deployment/activation        # revisions + change-cause
kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].image}'
```

**Roll back by hand:**
```bash
kubectl -n payments rollout undo deployment/activation                     # previous revision
kubectl -n payments rollout undo deployment/activation --to-revision=N     # a specific one
kubectl -n payments rollout status deployment/activation
```
Blue lines on dashboards = deploys. Red = rollbacks. Hover for the cause.

⚠️ Jenkins runs as **root with the Docker socket mounted** — root on the host. Lab only. Never in production.

Known gap: the pipeline deploys `<service>:<build#>` but `k8s/<service>.yaml` in git still pins the last hand-set tag. `kubectl apply -f` from the repo would revert to it. GitOps (committing the tag) is the fix; out of scope until later.

## The incident bot (Day 8) — the ticket layer

Alertmanager → `http://incident-bot.payments:8020/alertmanager` → one incident per **service**
outage, append-only timeline, auto-resolve when every alert in it clears.

| | |
|---|---|
| Code | `services/incident-bot/app.py` (tests in `tests/`) |
| Manifest | `k8s/incident-bot.yaml` — Deployment (1 replica, Recreate) + **PVC** + Service + ServiceMonitor |
| Routing | `k8s/kps-values.yaml` → `./scripts/81-alertmanager-route.sh` |
| CLI | `python3 tools/inc.py list \| show \| timeline \| note \| delete \| webhook` |
| Metrics | `incidents_open`, `incidents_created_total`, `alertmanager_webhooks_total{status}` — overview bottom row |
| Alert | `IncidentBotDown` — monitor the monitor |

**Routing opinions** (defend them): default receiver `null`; only alerts with a `service`
label become tickets; `Watchdog` never does; `group_by: [service]`; `group_wait 15s`,
`group_interval 2m`, `repeat_interval 4h`; `send_resolved: true`.

**AI drafts (Day 9).** `ai.py` drafts the internal summary + stakeholder update at open and
the resolution note + close-out + review skeleton at close, in a background thread, from the
record only. *The AI drafts; a human decides.* Provider via `AI_PROVIDER`
(`auto|anthropic|ollama|fake|none`), key in `secret/ai-keys` (`90-ai-secret.sh`) — never in
a file. Metrics `ai_drafts_total{kind,outcome}`, `ai_draft_latency_seconds`. Grades live in
`docs/ai-eval.md`.

**Context + diagnosis (Day 10).** At open, `enrich.py` fetches current metrics (Prometheus),
recent deploys/rollbacks of the service with their age (Grafana annotations, via a Viewer
service-account token) and top `app.reason` values (Splunk REST on 8089, admin login), attaches
them as `context`, and `ai.hypothesize()` writes a diagnosis — **diagnosis only, never
remediation.** Every collector degrades to an explanatory stub; `enrich_collector_total`
counts it. Credentials live in `secret/enrich-config` (`100-enrich-config.sh`).

⚠️ **Lab shortcuts, labelled:** records are JSON files on a single PVC (a real system uses a
database and runs more than one replica); `DELETE /incidents/{id}` exists for the smoke test
(real ticketing never deletes); no auth on the bot's API (it is only reachable in-cluster or
via the API server's proxy, which *is* authenticated); `SPLUNK_VERIFY=false` accepts Splunk's
self-signed certificate for the REST lookups.

## The activation service (Day 2)

The crown-jewel transaction: cashier scans a card, POS calls this API, card must
activate in well under a second.

| | |
|---|---|
| Code | `services/activation/app.py` |
| Manifest | `k8s/activation.yaml` (namespace `payments`) |
| Image | `activation:0.2` — rebuild with `./scripts/20-upgrade-activation.sh` |
| Dashboard | `dashboards/activation.json` — import into Grafana |
| Traffic | `./scripts/12-loadgen.sh [rps]` |

**Incident controls** — `kubectl set env deployment/activation -n payments <VAR>=<value>`

| Variable | Default | Simulates |
|---|---|---|
| `ERROR_RATE` | `0.02` | outright failures (500s) |
| `BASE_LATENCY_MS` | `80` | slow dependency |
| `FRAUD_SVC_DOWN` | `false` | dependency down → 503 |
| `FRAUD_TIMEOUT_S` | `3` | how long the dependency hangs |
| `FRAUD_CLIENT_TIMEOUT_S` | `0.3` | how long **we** wait (Day 7 fix) |

**eGift knobs** — `kubectl set env deployment/egift -n payments <VAR>=<value>`

| Variable | Default | Simulates |
|---|---|---|
| `DELIVERY_DELAY_MS` | `40` | slow email provider |
| `EMAIL_FAIL_RATE` | `0.01` | email delivery failures |
| `ACTIVATION_TIMEOUT_S` | `5` | how long eGift waits on activation |

**Settlement knobs** — `kubectl set env cronjob/settlement -n payments <VAR>=<value>` (future runs only)

| Variable | Default | Simulates |
|---|---|---|
| `SETTLEMENT_FAIL_MODE` | `none` | `crash` (loud) · `silent` (zero records, exit 0) |
| `SETTLEMENT_STRICT` | `true` (since Day 8) | `false` = the Day 5 behaviour: exit 0 on zero records |

Since `settlement:0.3` (Day 9) a failed run can no longer overwrite `settlement_last_success_timestamp` — it pushes with `pushadd` (POST) and only pushes the timestamp on real success.

**The three queries, and what normal looks like**

| Signal | PromQL | Normal |
|---|---|---|
| Request rate | `sum(rate(activation_requests_total[1m]))` | 5–8 req/s |
| Error rate % | `100 * sum(rate(activation_requests_total{status="error"}[1m])) / sum(rate(activation_requests_total[1m]))` | ~2% |
| p95 latency | `histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[1m])) by (le))` | ~0.1s |

---

## Docs

- **[DAY1.md](DAY1.md)** · **[CORRECTIONS-DAY1.md](CORRECTIONS-DAY1.md)**
- **[DAY2.md](DAY2.md)** · **[CORRECTIONS-DAY2.md](CORRECTIONS-DAY2.md)**
- **[DAY3.md](DAY3.md)** · **[CORRECTIONS-DAY3.md](CORRECTIONS-DAY3.md)**
- **[DAY4.md](DAY4.md)** · **[CORRECTIONS-DAY4.md](CORRECTIONS-DAY4.md)**
- **[DAY5.md](DAY5.md)** · **[CORRECTIONS-DAY5.md](CORRECTIONS-DAY5.md)** · **[docs/slos.md](docs/slos.md)**
- **[DAY6.md](DAY6.md)** · **[CORRECTIONS-DAY6.md](CORRECTIONS-DAY6.md)** · **[Jenkinsfile](Jenkinsfile)**
- **[DAY7.md](DAY7.md)** · **[CORRECTIONS-DAY7.md](CORRECTIONS-DAY7.md)** · **[docs/health-score.md](docs/health-score.md)** · **[docs/week1-review.md](docs/week1-review.md)**
- **[DAY8.md](DAY8.md)** · **[CORRECTIONS-DAY8.md](CORRECTIONS-DAY8.md)** · **[k8s/kps-values.yaml](k8s/kps-values.yaml)** · **[services/incident-bot/app.py](services/incident-bot/app.py)**
- **[DAY9.md](DAY9.md)** · **[CORRECTIONS-DAY9.md](CORRECTIONS-DAY9.md)** · **[services/incident-bot/ai.py](services/incident-bot/ai.py)** · **[docs/ai-eval.md](docs/ai-eval.md)**
- **[DAY10.md](DAY10.md)** · **[CORRECTIONS-DAY10.md](CORRECTIONS-DAY10.md)** · **[services/incident-bot/enrich.py](services/incident-bot/enrich.py)** · **[docs/ops-kpis.md](docs/ops-kpis.md)**
- **[splunk/searches.md](splunk/searches.md)** — incident search library
- **[incidents/INC-0001.md](incidents/INC-0001.md)** — first write-up
