# bhn-sim — local incident response lab

A fake production payments platform built to be broken on purpose.
Card activation API, eGift issuance, a nightly settlement job, flaky third-party mocks —
wrapped in metrics, logs, traces, dashboards, alerts, ticketing and an AI incident assistant.

**Host:** Windows + WSL2 Ubuntu · **Cluster:** kind · **Context:** `kind-bhn-sim`

> The test for this runbook: *if my laptop died tonight, could I rebuild from this file?*
> Since Day 13: `03-cluster-up.sh`, `./infra/local/tf.sh apply` (the platform layer), the
> secret scripts, one Jenkins build per service — see "Who owns what". Audited against the
> running lab on Day 14 (`./scripts/141-readme-audit.sh`); re-audit after every intense week.

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
./scripts/81-alertmanager-route.sh # new rules + Alertmanager routing (Day 8–12: helm upgrade; since Day 13 it refuses — use tf.sh)
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

# Day 11
./scripts/110-copilot-preflight.sh # every copilot tool once, no model; refusals proven
python3 tools/copilot.py           # ask production a question; -f questions.txt for a scripted run
./scripts/112-copilot-drill.sh     # fraud outage investigated by the copilot before the ticket opens (INC-0011)
./scripts/113-copilot-adversarial.sh --inject   # six attacks + a prompt-injected log line
./scripts/118-checkpoint-day11.sh

# Day 12
./scripts/120-remediator-config.sh # Grafana Editor token -> secret; RBAC proof (kubectl auth can-i --as=...); --check
./scripts/121-remediator-route.sh  # alert rules + webhook fan-out + synthetic end-to-end proof
./scripts/122-drill-tier1.sh crashloop|settlement   # automation acts, notes the OUTCOME (INC-0012, INC-0013)
./scripts/123-drill-tier2.sh apply|watch|revert     # bad deploy without Verify; proposal -> your approval -> rollback (INC-0014)
python3 tools/rem.py pending|approve <token>|decline <token>|actions|signatures
./scripts/128-checkpoint-day12.sh

# Day 13
./scripts/130-tf-import.sh         # pin chart versions from helm list, init, import 4 ns + 5 releases, plan
./infra/local/tf.sh plan|apply     # the platform layer, from now on (Splunk IP + TLS flag supplied by the wrapper; no secret is an input)
./scripts/131-tf-change.sh         # one real change: repeat_interval 4h -> 6h, edit-plan-apply-commit
./scripts/132-drift-drill.sh inject|detect|observe|repair   # a hand hot-fix, caught by plan, repaired by apply (INC-0015)
./scripts/134-tf-deterministic.sh  # Grafana password + HEC token out of the charts: plan deterministic, state secret-free
./scripts/133-drift-check-job.sh [--prove]   # terraform into the Jenkins image; nightly infra-drift-check job
./scripts/138-checkpoint-day13.sh

# Day 14 — game day (nothing new; measure, audit, drill)
./scripts/141-readme-audit.sh      # runbook rot: every command, port, job and fact in this file vs the running lab
./scripts/142-gameday.sh start     # runs gameday/scenario-1.sh in the background — do NOT read that file; walk away 5 min
./gameday/note.sh "what you see"   # the scribe: timestamped line into gameday/timeline-1.md (you are also the scribe)
./scripts/142-gameday.sh status    # the responder's view: open tickets, firing alerts, remediator actions, health scores
./scripts/142-gameday.sh verify    # when you believe it is over: knobs at baseline? tickets resolved? drafts written?
./scripts/142-gameday.sh retro     # ground truth vs your timeline; scaffolds INC-0016/0017 and gameday/retro-<n>.md
./scripts/148-checkpoint-day14.sh

# Day 15 — AWS foundations (guardrails first)
./scripts/150-aws-guardrails.sh [--install|--sso]   # CLI, SSO profile 'lab'; verifies root MFA, budget, Cost Explorer via the API
./scripts/151-aws-state.sh         # S3 state bucket (versioned, private, encrypted, S3-native lock) -> infra/aws/*/backend.hcl
./scripts/152-aws-vpc.sh plan|apply|destroy|status   # VPC (2+2 subnets, ONE NAT) + 5 ECR repos; destroy when pausing
./scripts/153-aws-ecr-push.sh [svc|--verify]         # buildx --platform linux/amd64 --push, tags mirrored from kind
./scripts/154-aws-cost.sh [--row N]                   # yesterday's bill by service (Cost Explorer, ~24 h lag; $0.01/call)
./scripts/155-aws-verify-destroyed.sh                 # EC2 / NAT / EIP / LB / EKS / ENI / EBS: anything still billing?
./scripts/158-checkpoint-day15.sh

# Any time, after a Docker restart / reboot
./scripts/up.sh                    # containers, kubeconfig, tombstones, knob reset, collectors, tf plan — docs/morning.md has the full routine
./scripts/up.sh --check            # read-only
./scripts/99-teardown.sh           # everything gone — the rebuild test (then: from the top of this file)
```

---

## Who owns what (Day 13)

| Layer | Owner | Changes happen by | "What changed?" |
|---|---|---|---|
| **Platform** — namespaces, the five Helm releases (kube-prometheus-stack, pushgateway, tempo, otel-collector, fluent-bit) and their values | **Terraform owns it**: `infra/local/` | edit `k8s/*-values.yaml` or the `.tf` → `./infra/local/tf.sh plan` → read → `apply` → commit | `git log infra/local k8s/*-values.yaml`; drift = `terraform plan -detailed-exitcode` (nightly in Jenkins: `infra-drift-check`) |
| **Application** — activation, egift, settlement, incident-bot, remediator | **CI/CD owns it**: `Jenkinsfile`, `k8s/<service>.yaml` | commit → Jenkins `deploy-service` → Verify → auto-rollback | rollout history, change-cause, Grafana deploy/rollback annotations, the bot's enrichment |
| **Data / secrets** — HEC token (`splunk-hec`), Grafana admin (`grafana-admin`), API key, Grafana SA tokens, Splunk password | scripts that mint them into Secrets (`22`, `134`, `90`, `100`, `120`) | re-run the script | never in git, never in Terraform state or plans (the charts read them from Secrets, B9/B10) |

Two owners for one object is how fights start: the `payments` Namespace moved out of
`k8s/activation.yaml` on Day 13 for that reason. "Who do I call about this layer?" is an
incident-response question; this table is the answer.

**Rebuild estimate.** Day 1 said 30 minutes of command replay. Now: `03-cluster-up.sh`,
`./infra/local/tf.sh apply` (the whole platform layer, ~5 min), the secrets scripts, then one
Jenkins build per service. State is local (`infra/local/terraform.tfstate`, gitignored — state
is not code, and after `134` it holds no secret); in a company it lives in a remote backend with locking, same shape.

---

## AWS (Day 15 onward)

**The standing rule:** everything in AWS is created by Terraform, so that `destroy` is
trustworthy. Nothing is clicked into existence except the three one-time guardrails (budget,
free-tier alerts, root MFA) and IAM Identity Center itself. A resource made in the console is
invisible to `destroy` and bills until someone notices.

| | |
|---|---|
| Region | **`us-east-2`** (Ohio) — one variable everywhere (`AWS_REGION` in `scripts/lib.sh`, `var.region` in `infra/aws/*`) |
| Identity | IAM Identity Center (SSO), profile `lab`, short-lived credentials. Login: `aws sso login --profile lab`. Sessions expire — that is the feature. *(Fallback, if ever used: an IAM user with MFA + access key — note it here; leaked long-lived keys are among the most common real cloud incidents.)* |
| State | `s3://<bucket in infra/aws/env/backend.hcl>` — versioned, private, encrypted, **locked by S3 itself** (`use_lockfile`, Terraform ≥ 1.10, no DynamoDB). Keys: `env/terraform.tfstate`, `platform/terraform.tfstate` (Day 16). The bucket root `infra/aws/backend` keeps *local* state (chicken-and-egg; it names one bucket). |
| Environment | `infra/aws/env`: VPC `10.0.0.0/16`, 2 public + 2 private subnets, **one** NAT gateway (the cost decision — see the comment in `vpc.tf`), subnet tags for EKS load balancers, 5 ECR repos with scan-on-push and a lifecycle policy. `./scripts/152-aws-vpc.sh plan` → read → `apply`; **`./scripts/152-aws-vpc.sh destroy` when pausing** (the NAT bills ~$1.10/day idle). |
| Images | `./scripts/153-aws-ecr-push.sh` — pushes **the image kind runs** (retagged from the local Docker daemon, architecture checked, digest printed) for all five, tags mirrored from the cluster; builds `--platform linux/amd64` from source only when the daemon no longer has one, and says so. `--verify` reads tags, architecture and scan findings back. Login is a 12-hour token from the SSO session (`aws ecr get-login-password`). |
| The bill | `./scripts/154-aws-cost.sh` every morning — **read the last three days, not just yesterday**: identical non-zero days before anything existed is how a $0.51/day leftover in another region was found on Day 15. `./scripts/155-aws-verify-destroyed.sh` after every destroy and every morning: the lab's region in detail, then **every enabled region** for anything that bills while idle (instances, EIPs, volumes, NAT, load balancers, customer KMS keys). *The lab lives in one region; the bill does not.* Rules and the per-day table: `docs/aws-costs.md`. |
| Cluster (Day 16) | `infra/aws/eks` — its **own state key**: EKS 1.33 by module v21, 2 × t3.medium **SPOT**, add-ons declared (v21 installs none by itself), prefix delegation, **Pod Identity** for the two pods that need AWS (EBS CSI, Fluent Bit). `./scripts/160-eks.sh plan` → read → `apply` (~15 min) → `161` writes context **`aws-lab`** (exec auth from SSO; the current-context is never changed). |
| Platform on EKS | `infra/aws/platform` — the Day 13 root with three differences: context `aws-lab`, Fluent Bit → **CloudWatch** (`k8s/fluent-bit-cloudwatch.yaml.tmpl`, no credential), and `k8s/kps-values-eks.yaml` (a control plane you do not run is not scraped). Charts from a **local cache** (`tf.sh`, D4). `./scripts/162-eks-platform.sh plan` → `apply`. |
| Services on EKS | `./scripts/163-eks-deploy.sh` renders `k8s/aws/` from `k8s/` (image line → ECR, kind's NodePort doors dropped — `diff -r k8s k8s/aws` is the whole difference), copies `secret/ai-keys` cluster-to-cluster, applies, wires the bot and remediator with the **same scripts** under `KUBE_CONTEXT=aws-lab`. Traffic: `164`. Drill: `165` (INC-0018). Differences, with evidence: `166` → `docs/eks-notes.md`. |
| Teardown | `./scripts/167-eks-teardown.sh` — LoadBalancer Services reverted, platform destroyed, cluster destroyed, the CloudWatch group removed, **`155` across every region**. `--all` takes the VPC/NAT/ECR too. |
| Any script, either cluster | `KUBE_CONTEXT=aws-lab ./scripts/<anything>.sh` — every kubectl call in `scripts/lib.sh` and every Python tool is pinned to that variable (default: kind). `GRAFANA_PORT=3001` keeps the EKS Grafana off kind's port. |
| Rebuild | `151` (bucket, if gone) → `152 plan/apply` → `153` — about ten minutes to a warm start; `160` → `162` → `163` another fifteen for the cluster. |

---

## Week 3 — AWS (the plan, written on Day 14)

Weeks 1–2 built the skills on a laptop; week 3 moves the ground truth to where the job lives.
Rules first (`docs/aws-costs.md`): budget alarm before the first resource, everything through
Terraform so `destroy` works, smallest nodes, no NAT gateway unless a step needs it, nothing
running overnight, the bill checked every morning.

| Day | What | Cost discipline |
|---|---|---|
| 15 | AWS foundations, the safe way: **billing guardrails first**, IAM (no root, MFA, one lab role), Terraform **remote state** (S3 + lock), a real VPC, ECR with the five images pushed | no compute; cents |
| 16 | **EKS** stood up by Terraform (its own root), the platform layer applied onto it with three commented differences, the five services from ECR, the Day 10 drill unchanged (INC-0018), six differences written with evidence — then **destroyed the same day, verified in every region**. *Create, learn, destroy.* | ≈$3–4 for the hours it exists |
| 17–18 | cloud-native observability: CloudWatch (metrics, logs, alarms) and the New Relic account from Day 1 wired in; the incident stack (bot, remediator, copilot) running against EKS | logs retention set; cluster destroyed nightly |
| 19–20 | final game day on AWS; the write-up; the repo as the portfolio piece and the first-90-days plan | destroy everything; the final bill in `docs/aws-costs.md` |

Prework before Day 15: the AWS account exists (README → Hosted accounts), MFA on root, the
budget email is one you read, and `aws --version` works in WSL.

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
| **Copilot** | `python3 tools/copilot.py` (`new` / `exit`) · `-q "question"` · `-f docs/copilot-questions/warmup.txt` · transcripts in `docs/copilot-transcripts/` |
| **Platform layer (IaC)** | `./infra/local/tf.sh plan` (drift?) · `apply` · `python3 tools/inc.py declare <service> "why"` for incidents nothing alerts on |
| **Remediation** | `python3 tools/rem.py pending` · `approve <token>` · `decline <token>` · `actions` · `signatures` — policy in `docs/remediation-policy.md` |
| **Ad-hoc Splunk from the shell** | `python3 tools/inc.py search 'app.service=activation app.status=error \| stats count by app.reason' -10m` |
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
| Routing | `k8s/kps-values.yaml` → `./infra/local/tf.sh plan` → `apply` (Terraform owns kps since Day 13; `81-alertmanager-route.sh` was the Day 8–12 way and now refuses) |
| CLI | `python3 tools/inc.py list \| show \| timeline \| note \| delete \| webhook` |
| Metrics | `incidents_open`, `incidents_created_total`, `alertmanager_webhooks_total{status}` — overview bottom row |
| Alert | `IncidentBotDown` — monitor the monitor |

**Routing opinions** (defend them): default receiver `null`; only alerts with a `service`
label become tickets; `Watchdog` never does; `group_by: [service]`; `group_wait 15s`,
`group_interval 2m`, `repeat_interval 6h` (4h until Day 13's first Terraform change); `send_resolved: true`.

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

**The copilot (Day 11).** `tools/copilot.py` — a tool-use loop: the model answers questions by
calling six **read-only** tools (Prometheus, alerts, a validated Splunk search *via the bot*,
allow-listed kubectl, the records). The tool menu is the permission boundary: `rollout` only
`status|history`, secrets/configmaps refused, no `-f`, context-pinned; SPL side-effect commands
refused by the bot's `POST /tools/search_logs` (0.4). Key read from `secret/ai-keys` at start.
Every session writes a transcript; grades in `docs/ai-eval.md` Eval 4. Tool results are data,
never instructions — and that is tested (`113 --inject`).

**The remediator (Day 12).** `services/remediator/` — auto-remediation with the safety on. Three
tiers (`docs/remediation-policy.md`): tier 1 runs and notifies after (delete a crash-looping pod,
re-run settlement), tier 2 proposes with a single-use token and a human approves (`rollout undo
deployment/activation` after a deploy within 30 min), tier 3 = no signature = "human required"
on the ticket (the fraud outage, on purpose). Same Alertmanager fan-out as the bot; every action
is a `[remediator]` note on the incident; cooldown, bounded retry, token expiry, withdrawal.
**The safety is RBAC** (`k8s/remediator.yaml`): pods delete, jobs create, patch *one* deployment,
*one* namespace — proven by `120-remediator-config.sh --check`. Metrics
`remediation_actions_total{signature,mode,result}` on the overview's bottom row.

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
| Manifest | `k8s/activation.yaml` (Deployment/Service/ServiceMonitor; the `payments` Namespace is Terraform's since Day 13) |
| Image | `activation:<jenkins build#>` — built and deployed by the pipeline since Day 6 (`Jenkinsfile`, `SERVICE=activation`); currently v0.4 (fail-fast, Day 7). `20-upgrade-activation.sh` is the Day 3 hand-build, kept for history |
| Dashboard | `dashboards/activation.json` → `./scripts/09-grafana-dashboards.sh` (ConfigMaps; UI imports do not survive a Grafana restart) |
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
- **[DAY11.md](DAY11.md)** · **[CORRECTIONS-DAY11.md](CORRECTIONS-DAY11.md)** · **[tools/copilot.py](tools/copilot.py)** · **[docs/copilot-questions/](docs/copilot-questions/)**
- **[DAY12.md](DAY12.md)** · **[CORRECTIONS-DAY12.md](CORRECTIONS-DAY12.md)** · **[docs/remediation-policy.md](docs/remediation-policy.md)** · **[services/remediator/app.py](services/remediator/app.py)** · **[k8s/remediator.yaml](k8s/remediator.yaml)**
- **[DAY13.md](DAY13.md)** · **[CORRECTIONS-DAY13.md](CORRECTIONS-DAY13.md)** · **[infra/local/](infra/local/)** · **[ci/Jenkinsfile.drift](ci/Jenkinsfile.drift)**
- **[splunk/searches.md](splunk/searches.md)** — incident search library
- **[incidents/INC-0001.md](incidents/INC-0001.md)** — first write-up
