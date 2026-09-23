# Rebuild from zero — the order that works on today's repo

*Tested for real on 23 Sep 2026, after Docker Desktop was wiped: containers, networks and the
cluster gone; images and the `jenkins_home` volume survived. The day-by-day replay in the
README's runbook is the history of how the lab was built; it does not rebuild today's lab,
because since Day 13 Terraform owns the platform layer and since Day 6 Jenkins owns the
services. This is the sequence that does. What broke on the way is `CORRECTIONS-REBUILD.md`.*

**What cannot come back:** the incident-bot's live records (ticket numbers, timelines) lived on
a local-path PVC inside the kind node and died with it. `incidents/INC-*.md` in git are the
permanent record; the bot starts an empty store. Splunk's indexed logs and Prometheus's history
are gone the same way. Everything else below is rebuilt from git plus three secrets you type.

**Wall clock, 23 Sep:** one afternoon, most of it the four failures in the corrections file.
With `135` doing the platform layer in the right order, the honest estimate is **about an hour**:
~10 min cluster + containers, ~15 min platform (kps pulls seven images), ~25 min for five
pipeline builds, ~10 min of secrets and checks.

## 0. Before anything: is Docker answering, and is there disk?

```bash
timeout 15 docker version --format '{{.Server.Version}}'   # a number, not a hang (B4)
df -h /mnt/c                                               # C: holds both VMs' disks; < 5 GB free is a warning
```

## 1. Cluster and the two containers outside it

```bash
./scripts/03-cluster-up.sh          # kind cluster bhn-sim, context kind-bhn-sim
./scripts/21-splunk-up.sh           # NEW container = new 60-day trial; then, in the UI:
                                    #   HEC Global Settings: All Tokens Enabled, SSL off; New Token "k8s"
./scripts/50-jenkins-rebuild.sh     # image jenkins-lab (survives), volume jenkins_home (jobs survive);
                                    # regenerates ci/kubeconfig-internal.yaml for the NEW cluster
```

## 2. The platform layer — one script, in the order an empty cluster needs

```bash
./scripts/135-platform-from-zero.sh    # namespaces -> 3 secrets (prompts) -> Operator CRDs -> apply
                                       # -> untaint the first-install ghosts -> plan must be empty
```

It asks for: a Grafana admin password (yours to choose — the old one died with the cluster),
the New Relic INGEST – LICENSE key (40 chars, ends `NRAL`), and the HEC token from step 1.

## 3. Grafana and Prometheus content

```bash
kubectl apply -f k8s/grafana-datasource-tempo.yaml
./scripts/09-grafana-dashboards.sh
kubectl apply -f k8s/alerts.yaml
./scripts/100-enrich-config.sh      # Grafana Viewer token + Splunk REST address for the bot's collectors
./scripts/90-ai-secret.sh           # Anthropic key -> secret/ai-keys (prompted, verified)
```

## 4. The five services — through the pipeline, the only door

Jenkins `http://localhost:8081` → deploy-service → Build with Parameters. A **first** deploy
has no baseline and no traffic, so its Verify can only fail (B5, B6): tick **SKIP_VERIFY** for
the first build of activation and egift, start their load generators, then build them again
without it — that second build is the verified one.

| Order | SERVICE | Notes |
|---|---|---|
| 1 | activation | SKIP_VERIFY; then `./scripts/12-loadgen.sh` (own terminal); build again |
| 2 | egift | SKIP_VERIFY; then `./scripts/33-loadgen-egift.sh`; build again |
| 3 | settlement | Verify runs one job from the CronJob |
| 4 | incident-bot | Ready for 30 s, no restarts |
| 5 | remediator | then `./scripts/120-remediator-config.sh` (Editor token + the RBAC proof) |

```bash
./scripts/172-kb.sh                 # kb/*.md -> ConfigMap, bot restarted, /ai lists all entries
```

## 5. Proof

```bash
./scripts/up.sh --check             # every line ok; "plan clean"; collectors metrics/deploys/logs ok
```

Then run Jenkins `infra-drift-check` once: green means the Jenkins container, with its own
kubeconfig, sees the same cluster and the same state as your shell.
