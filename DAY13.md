# Day 13 — Infrastructure as Code, Locally

Adapted from `day13infrastructureascode.pdf`. Changes in **[CORRECTIONS-DAY13.md](CORRECTIONS-DAY13.md)**.

> The PDF's Terraform pins no chart versions (the first `apply` would upgrade all five
> charts), drops three of pushgateway's five install flags (the first plan would remove
> `honorLabels` and look like an "import diff"), reads a gitignored file with the HEC token
> in it, gives the `payments` Namespace two owners, describes a Jenkins job that cannot run
> (no terraform, no state, no secrets, a lock file every night), and asks for an incident
> ticket on an alert that cannot fire. All fixed; the log has the details.

---

## What we're building today, and why — read this first

**The gap.** Everything the platform does — detect, record, enrich, diagnose, remediate —
runs on foundations that exist only as a trail of commands in the README: four namespaces,
five Helm releases, their values. If the cluster died, rebuilding it is replaying two weeks
of shell history and hoping. Worse for incident response: application changes are tracked
(pipeline, change-cause, annotations, the bot's deploy collector). **Infrastructure changes
are the untracked class** — someone editing Alertmanager's routing, bumping a chart, turning
a ServiceMonitor off "for a minute" — and they cause the confusing incidents, the ones where
nothing crashed and nothing alerted and a metric just stopped.

**Terraform closes it** by making the platform layer files: changes become diffs, "what
changed at the platform layer?" becomes `git log`, and *the difference between what the
code says and what the cluster is* becomes a command with an exit code. That last part is
the incident-response payoff and it has a name: **drift**.

**Three skills, in order.**

1. **Import, don't recreate.** The platform is running and must keep running. You write
   code that describes it, then *attach* each real object to its resource (`terraform
   import`), then `plan` until it says *no changes* — at which point the code provably
   describes reality. This is what joining any company with existing infrastructure feels
   like, and it is the least-taught Terraform skill.
2. **Edit → plan → read the plan → apply → commit.** One real change (Alertmanager
   `repeat_interval` 4h → 6h) done the way it is done every day at every company. On Day 8
   the same class of change was a helm command you remembered or not.
3. **Drift, detected and repaired.** A colleague hot-fixes pushgateway by hand; Prometheus
   quietly stops scraping settlement's metrics; no alert *can* fire. `terraform plan
   -detailed-exitcode` returns 2 and names the line. `apply` restores it. A nightly Jenkins
   job makes exit 2 a red build — infrastructure drift is now an alert like any other.

**The boundary.** Terraform owns the *platform* layer (namespaces, the five releases and
their values). The pipeline owns the *application* layer (activation, egift, settlement,
incident-bot, remediator). Two owners for one object is how fights start, which is why the
`payments` Namespace leaves `k8s/activation.yaml` today. The README gets a "who owns what"
table — "who do I call about this layer?" is an incident-response question.

**What stays out of git.** Terraform *state* records what it manages, including the Fluent
Bit values — which carry the HEC token. State is gitignored; the chart pins and the code are
committed. In a company state lives in a remote backend with locking; same shape.

---

## Before you start

`./scripts/up.sh` green; Day 12 checkpoint 22/22; `python3 tools/inc.py list open` empty;
`docker ps` shows `splunk` (Terraform renders its IP into the Fluent Bit values);
`terraform version` ≥ 1.9 (`01-install-tools.sh` installed it on Day 1).

```bash
cd ~ && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day13.zip').extractall('/tmp/day13')"
cp -r /tmp/day13/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/tools/*.py ~/bhn-sim/infra/local/tf.sh
cd ~/bhn-sim && git status --short
```

Budget: ~2 hours. The import (≈10 min incl. one no-op apply of kps), the change (≈5),
the drift drill (≈10), the Jenkins job (≈15 with the image rebuild), the write-up.

---

## Part A — Describe, then import

**Step 1 — Read `infra/local/`.** `versions.tf` (providers, terraform ≥ 1.9, local
backend), `providers.tf` (the pinned `kind-bhn-sim` context — a provider pointed at the
wrong cluster is a classic self-inflicted outage), `namespaces.tf`, `releases.tf` (five
releases, every one `version = var.chart_versions[…]`, every one with the values file the
earlier days used), `variables.tf`, and `tf.sh` — the wrapper every command goes through,
because three inputs live outside git: Splunk's IP, the HEC token, and the state path.

**Step 2 — Commit the code before touching state:**

```bash
git add -A && git commit -m "Day 13: infra/local (Terraform for the platform layer), pushgateway values file, inc.py declare"
```

**Step 3 — Pin, init, import, plan:**

```bash
./scripts/130-tf-import.sh
```

Writes `chart-versions.auto.tfvars` from `helm list -A` (reality), inits, imports the four
namespaces and five releases (idempotent), then runs `plan -detailed-exitcode`. **Read the
result.** Exit 0: clean, nothing to do. Exit 2: the script prints the diff with a legend —
`~ values` and `~ repository/timeout/wait` are the expected once-after-import diffs (Helm
stores the parsed map and forgets the flags); `~ version` or any `-`/`+` means stop. When
only the expected diffs remain:

```bash
./infra/local/tf.sh apply        # type yes — a no-op upgrade per release (revision +1)
./infra/local/tf.sh plan -detailed-exitcode; echo "exit $?"     # expect 0
git add infra/local && git commit -m "Day 13: platform layer imported, plan clean"
```

---

## Part B — One change, the IaC way

**Step 4:**

```bash
./scripts/131-tf-change.sh
```

Edits `k8s/kps-values.yaml` (`repeat_interval: 4h` → `6h`), plans — exactly `0 to add,
1 to change, 0 to destroy`, and only that key — **waits for you to read it**, applies (a
pinned `helm upgrade` under the hood), verifies in Alertmanager's live config (the reloader
polls; up to ~2 min), commits. The change now has a diff, an author and a timestamp.

---

## Part C — Drift (INC-0015)

**Step 5 — inject, detect, observe, repair:**

```bash
./scripts/132-drift-drill.sh inject     # the hot-fix: helm upgrade --set serviceMonitor.enabled=false, by hand
./scripts/132-drift-drill.sh detect     # terraform plan -detailed-exitcode -> 2, and the exact line
./scripts/132-drift-drill.sh observe    # what the platform sees, and a human-declared ticket
./scripts/132-drift-drill.sh repair     # terraform apply; metrics return; ticket closed
```

`observe` is the incident: settlement's panels blank, `SettlementStale`'s expression
**empty** (it cannot fire, however stale settlement gets), the bot's collector reporting no
data, the copilot asked "is settlement healthy?" — it must say *not available*, not a
number. Then `inc.py declare settlement "…"` opens the ticket nobody else will, and the drift
line from `detect` goes on it. Between `inject` and `repair`, open Grafana's settlement
panels yourself: that blank is what "silently stopped flowing" looks like at 03:00.

**Step 6 — the nightly job:**

```bash
./scripts/133-drift-check-job.sh --prove
```

Asks for the Jenkins password (never stored). Rebuilds `jenkins-lab` with terraform if it
lacks it (jobs and history survive in the volume), creates `infra-drift-check` from
`ci/infra-drift-check.job.xml` (`ci/Jenkinsfile.drift`, cron `H 3 * * *`), runs it three
times: clean → **SUCCESS**, drifted → **FAILURE** (it reads the plan's exit code, not its
text), repaired → **SUCCESS**. A drift check you have never seen fail is not a check.

---

## Part D — Write it down

**Step 7** — `incidents/INC-0015.md` from the ticket (`python3 tools/inc.py timeline <id>`)
and `checkpoints/day13-drift-injected.txt`: root cause category **untracked infrastructure
change**; permanent fix **the nightly drift check**. Two clocks (CORRECTIONS D4): injected →
detected, declared → repaired. `docs/ops-kpis.md`: row 0015 with detection = *none
(declared)* — the honest value, and the reason the job exists.

---

## Wrap

```bash
git add -A && git commit -m "Day 13: drift drill (INC-0015), nightly infra-drift-check, ownership boundary"
./scripts/138-checkpoint-day13.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `130`: `terraform >= 1.9 required` | `sudo apt-get update && sudo apt-get install --only-upgrade terraform` |
| `130`: `import failed … cannot find release` | the ID is `namespace/name` and the name is what `helm list -A` shows |
| plan after import shows `~ version` | the pins are wrong: re-run `130` (it rewrites the tfvars from `helm list`) |
| plan after import shows `-` destroy or `+ create` | an import is missing or the address is wrong — do **not** apply; `./infra/local/tf.sh state list` |
| plan shows the whole kps `values` block | whitespace/ordering (Helm stores the parsed map): `helm get values kps -n monitoring` vs the file; if the keys agree, apply once |
| plan hangs | wrong context or cluster down — `kubectl config current-context`, `./scripts/up.sh --check` |
| plan shows one Fluent Bit diff on the `Host` line | Splunk's IP moved (Docker restart): `./scripts/22-fluent-bit.sh "$(grep -oE '[0-9a-f-]{36}' k8s/fluent-bit-values.yaml \| head -1)"` then plan again — or apply, which is the same fix from the other side |
| `tf.sh: splunk container not running` | `docker start splunk` — Terraform needs its IP to render the values |
| `131`: Alertmanager still shows 4h after 2 min | `kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c config-reloader` |
| `132 detect`: plan is clean | `helm get values pushgateway -n monitoring` — did inject run? |
| `132 observe`: copilot invented a number | grade it ❌ on the ticket; the tool result said no data |
| `133`: Run 2 went **green** with drift present | the job planned against a different state: check `TF_STATE_PATH` in the console (`/repo/infra/local/terraform.tfstate`) |
| `133`: `no state at /repo/…` | run `130` first; the job never creates state |
| `.terraform.tfstate.lock.info` appears in `infra/local` | a plan was killed mid-run: `./infra/local/tf.sh force-unlock <id>` |
| a plan in Jenkins fails with `no rendered k8s/fluent-bit-values.yaml` | the bind mount lost the file — `./scripts/22-fluent-bit.sh` to re-render |

---

## What's next

Day 14 closes week 2 the way Day 7 closed week 1: consolidation, a KPI review across all
fifteen incidents, a full game-day where everything runs at once against a surprise
failure, and the plan for week 3 — AWS.
