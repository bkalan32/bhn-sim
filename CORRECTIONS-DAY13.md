# Day 13 — Corrections Log

Source: `day13infrastructureascode.pdf` · Verified 8 September 2026 against the running lab.

---

## [BUG] B1 — No chart is pinned, so the first `apply` is five surprise upgrades

**Guide, Step 2:** every `helm_release` has `repository` and `chart` and **no `version`**.
Without a version the helm provider resolves "newest in the repo" on every plan. The day
after import, `terraform apply` for *any* reason (Step 4's `repeat_interval` change, Step 5's
drift repair) would upgrade kube-prometheus-stack, pushgateway, tempo, the collector and
Fluent Bit to whatever is current that morning — the exact Day 8 lesson ("pin the chart
version, or a config change becomes an upgrade") applied five times at once, and the plan
would show it as `~ version` buried under a values diff. **Substitute:** `variables.tf`
declares `chart_versions` (a map), every release has `version = var.chart_versions["…"]`,
and `130-tf-import.sh` writes `infra/local/chart-versions.auto.tfvars` from `helm list -A`
**on the day of import** — reality, not a guess — and that file is committed. `130` flags
`~ version` in a post-import plan as "your pins are wrong", and `138` fails if a release is
unpinned.

---

## [BUG] B2 — The pushgateway resource drops three of Day 5's five `--set` flags

**Guide, Step 2:** `set = [serviceMonitor.enabled, serviceMonitor.additionalLabels.release]`.
`42-install-pushgateway.sh` installed it with five: those two plus
`serviceMonitor.honorLabels=true` and the CPU/memory requests and limit. The first plan after
import would therefore *not* be clean — it would propose removing `honorLabels` (the
settlement job's own `job="settlement"` label would be overwritten, and every Day 5 rule
and panel keyed on it would go blank) and the resource limits. Worse, it looks like an
"import diff" (B-troubleshooting: "reconcile the file") and the obvious reflex is to apply
it. Tempo has the same problem: the PDF gives it no values at all, while Day 4 installed it
with `k8s/tempo-values.yaml`. **Substitute:** the five flags became
`k8s/pushgateway-values.yaml` (with the *why* of each as a comment); the resource uses
`values = [file(...)]` like the other four; tempo gets its Day 4 file. The rule the PDF
states but does not follow: Terraform says what helm said, or the plan lies.

---

## [BUG] B3 — `file("k8s/fluent-bit-values.yaml")` reads a gitignored file with a secret in it

**Guide, Step 2:** the Fluent Bit release takes `values = [file("…/k8s/fluent-bit-values.yaml")]`.
That file is *rendered* by `22-fluent-bit.sh` from a template, contained the HEC token, and
is gitignored for that reason (Day 3). So: the Jenkins drift job's clone has no such file
(plan → error), the committed code cannot describe the release, and the token enters
Terraform state. **Substitute:** `releases.tf` renders the *template*
(`k8s/fluent-bit-values.yaml.tmpl`, committed) with the two non-secret inputs the template
cannot know — `splunk_ip` (moves on every Docker restart) and `splunk_hec_tls` — exactly as
the sed in `22` does. `infra/local/tf.sh` supplies them as `TF_VAR_*` from `docker inspect
splunk` and the rendered file; every `terraform` command today goes through `tf.sh`. The
token itself is handled in B9 — it is no longer an input at all. State stays gitignored
regardless (`infra/local/terraform.tfstate*`, `.terraform/`, `plan.txt`, every `*.tfvars`
except the chart pins; `.terraform.lock.hcl` is committed on purpose — it pins provider
builds the way the tfvars pins charts).

Side effect that is a feature: after a Docker restart moves Splunk's IP, `tf.sh plan` shows
one line of drift — the `Host` — which is the Day 10/11 "Splunk moved" failure detected by
the platform layer instead of by a failed log search.

---

## [BUG] B4 — The `payments` Namespace would have two owners

**Guide, Step 2:** `kubernetes_namespace.payments` — and then: *"two owners for one object
is how fights start."* `k8s/activation.yaml` has declared `kind: Namespace payments` since
Day 2 and Jenkins `kubectl apply`s it on every activation build. Terraform importing it means
every pipeline run re-asserts a Terraform-owned object (harmless today, a real fight the day
Terraform adds a label). **Substitute:** the Namespace document is removed from
`k8s/activation.yaml` (a comment says where it went); the namespace exists, so Jenkins deploys
keep working; the checkpoint fails if `kind: Namespace` reappears there. The README's
ownership table (Step 2's assignment) is written.

---

## [BUG] B5 — The nightly Jenkins job cannot run as described

**Guide, Step 5:** *"add a Jenkins job (`infra-drift-check`) that runs `terraform plan
-detailed-exitcode` nightly."* One sentence; five things stop it: (1) the Jenkins image has
no terraform — `ci/Dockerfile.jenkins` now installs a pinned 1.13.3 and `50-jenkins-rebuild.sh`
checks for it; (2) the job clones the repo, and the clone has **no state** — `plan` against an
empty state is nine `+ create`, exit 2, drift every night forever; `tf.sh` takes
`TF_STATE_PATH` and the job points it at `/repo/infra/local/terraform.tfstate` through the
bind mount that has existed since Day 6, so it plans against *your* state; (3) the clone has
no rendered Fluent Bit values and no HEC token — B3's `tf.sh` reads them from `/repo` and
`docker inspect`; (4) a plan writes a lock file — `-lock=false`, because a read-only nightly
plan must never leave `.terraform.tfstate.lock.info` in your working tree for you to find
the next morning; (5) providers would download every night — `TF_PLUGIN_CACHE_DIR` in
`jenkins_home`. Also `set -o pipefail` before `| tee plan.txt`, or the exit code the whole
job exists to read is `tee`'s (Day 12, B9). `133-drift-check-job.sh --prove` runs the job
three times — clean, drifted, repaired — and expects SUCCESS / FAILURE / SUCCESS, because a
drift check that has never been seen to fail is not a check.

---

## [BUG] B6 — "Fire the settlement staleness path" cannot open a ticket

**Guide, Step 5:** *"with the drift in place, fire the settlement staleness path and note how
much harder diagnosis is."* With the ServiceMonitor gone, `settlement_last_success_timestamp`
has no series, so `time() - settlement_last_success_timestamp > 900` is **empty** — the
alert cannot fire *however stale settlement gets*. No alert → no webhook → no ticket → no
INC record to write. That is the lesson, but the PDF wants a record of it. **Substitute:**
`tools/inc.py declare <service> "why"` opens a **human-declared** incident by sending the bot
a synthetic firing webhook (`alertname=HumanDeclared`, `severity=warning`, a `declared=human`
label so the group key never collides with a real alert) and `undeclare` resolves it — the
same path every real ticket takes, so enrichment, drafts and the copilot all work on it.
`132-drift-drill.sh observe` shows the blank metrics, the empty alert expression, the bot's
collector reporting no data, the copilot saying "not available" (graded: it must not invent
a number), *then* declares. Silent incidents are declared by humans in every company; now
the lab has the button.

---

## [BUG] B7 — My own: `130` piped helm's JSON into a heredoc

`helm list -o json | python3 - <<'PY'` — the heredoc *is* python's stdin, so the JSON was
never read (`Expecting value: line 1 column 1`), and helm, writing into a pipe nobody read,
reported the cluster "unreachable" — which sent us checking a healthy cluster. The JSON now
goes through a temp file, with a three-try loop for the real transient case. Same shape as
Day 12's B11: when a parser says "empty", look at what fed it before looking at the source.

---

## [BUG] B8 — The headline claim is false: `terraform plan` does not see the drift

**Guide, Step 5:** *"`terraform plan` — Terraform reports the drift precisely:
serviceMonitor.enabled is false, code says true."* It does not. After the hand `helm upgrade
--set serviceMonitor.enabled=false --reuse-values`, the plan was **clean (exit 0)**. Read the
provider (`resource_helm_release.go`, `Read`): a refresh re-reads the release's *computed*
metadata and nothing else; the `values` you wrote are configuration, never compared with
what the release is running. A hand hot-fix is invisible to Terraform forever — the exact
class of change the day exists to catch. **Substitute:** `experiments = { manifest = true }`
on the helm provider (`providers.tf`). Then every plan runs a *dry-run upgrade* with your
values and diffs the rendered manifest (and the set of live resources) against what the
cluster holds — a missing ServiceMonitor is a diff, exit 2. Two costs, both real: plans take
a few seconds longer per release, and the rendered manifests now live in state and in plan
output — see B9. `132 detect` names both causes when a plan comes back clean.

---

## [BUG] B9 — With the manifest diff on, the HEC token would be in every plan

B8's fix renders every chart at plan time and stores the result in state and in plan
output — which the Jenkins job archives as `plan.txt`. The token was inside the Fluent Bit
values (`Splunk_Token <uuid>`), so it would have been in the rendered ConfigMap in state and
printed in the console the day the Splunk IP moved. The provider redacts only
`set_sensitive` entries, and the token sits inside a multi-line config string where
`set_sensitive` cannot reach. **Substitute:** the token leaves the values entirely. Fluent
Bit substitutes `${SPLUNK_HEC_TOKEN}` from its environment; the DaemonSet gets that env
var from `secret/splunk-hec`, which `22-fluent-bit.sh` creates with `kubectl` — a Secret
minted by a script, like every other secret in the lab (README, "Data / secrets"). `22` no
longer runs `helm upgrade` once Terraform owns the release. `134-tf-deterministic.sh` does
the migration and proves it: `grep` of the token against `terraform.tfstate` finds nothing,
and the previous state's `.backup` is removed. The rendered values file now carries only an
IP and a TLS flag; it stays gitignored because it is derived, not because it is secret.

---

## [BUG] B10 — kps showed drift on every plan: Grafana's password is random at render time

The first plan with the manifest diff on listed **kps** as changed, with no change of
ours: `secret/kps-grafana admin-password` and the Deployment's `checksum/secret`. With no
`adminPassword` in the values, the Grafana subchart renders `randAlphaNum` and relies on
Helm's `lookup` to keep the existing password on a real upgrade — and `lookup` returns
nothing in a dry run. Every plan: new random password, new checksum, "drift". Worse than a
permanently red nightly check: **apply breaks**. Terraform re-renders at apply time, gets a
*third* random password, sees a value that differs from the plan it is executing, and
refuses — `Provider produced inconsistent final plan` — which is exactly how the drift
drill's `repair` died the first time (the ServiceMonitor came back only because pushgateway
applied in parallel before kps failed). **Substitute:** `grafana.admin.existingSecret:
grafana-admin` in `k8s/kps-values.yaml`; `134` mints that Secret from the chart's own, so the
password you log in with does not change; the chart renders no secret; the plan is stable.
Grafana restarts once (the checksum annotation changes) and, with no persistence, forgets its
service accounts — `134` re-runs `100` and `120` to mint the bot's and the remediator's
tokens, and `09` for the dashboards. Every script that read `secret/kps-grafana` now goes
through `grafana_admin_password()` in `lib.sh` (ours first, the chart's as fallback).

---

## [DESIGN] D1 — Exit codes are the interface

`terraform plan -detailed-exitcode`: 0 clean, 1 error, 2 drift. Everything today reads that
number — the checkpoint, the drift drill, the Jenkins job — rather than grepping "No
changes". A plan that *fails* (1: cluster down, wrong context, no state) must be
distinguishable from drift (2): the first is "the check is broken", the second is "the
platform changed". The Jenkins job reports them with different messages.

## [DESIGN] D2 — The hot-fix is pinned too

The drift injection (`helm upgrade --set serviceMonitor.enabled=false --reuse-values`) passes
`--version` from the committed pins. Without it, the "colleague's hot-fix" would also upgrade
the chart, and `terraform plan` would report *two* diffs — version and values — muddying the
one-line lesson. Real hot-fixes do exactly that, which is a second argument for the nightly
check, but the drill isolates one variable.

## [DESIGN] D3 — Import is idempotent, and reads the plan for you

`130-tf-import.sh` skips addresses already in state and, on exit 2 after import, prints the
diff with a legend: `~ values` (whitespace/ordering — verify with `helm get values`, then a
no-op apply), `~ repository/timeout/wait` (Helm does not store them; first apply records
them), `~ version` (your pins are wrong — stop), `-`/`+` (an import is missing — stop).
"Chase each one until you understand it" is the PDF's instruction; the script does the first
half of the chasing.

## [DESIGN] D4 — Two clocks on INC-0015

There is no alert on this incident, so "alert → resolved" is undefined. The record keeps two
times instead: *declared → repaired* (the human clock) and *injected → detected* (the
platform clock: the nightly job would have caught it at 03:00; `detect` caught it when you
ran it). Both go into `docs/ops-kpis.md` with detection = **none (declared)**, which is the
honest value and the reason the drift job exists.

## [DESIGN] D5 — Step 6 (rebuild on a second cluster) is not scripted

It is optional in the PDF and would download every image again on a WSL laptop that has
already had its share of `wsl --shutdown`. The README's rebuild estimate is updated from
the real artefacts instead: `03-cluster-up.sh`, `tf.sh apply`, the secret scripts, one build
per service. If you have the hour, `kind create cluster --name bhn-sim-2` and
`TF_VAR_kube_context=kind-bhn-sim-2 TF_STATE_PATH=/tmp/bhn2.tfstate ./infra/local/tf.sh apply`
is the whole experiment; delete the cluster after.

---

## [NOTE] N0 — `grep Error` on a Terraform apply

The first `repair` printed two hundred lines of manifest JSON: with the manifest diff on, a
plan contains rendered PrometheusRules, and their alert names contain "Error". Every script
now writes the apply to `infra/local/apply.txt`, greps for lines that *start* with
`helm_release`, `Apply complete` or `Error:`, and dies on a non-zero exit instead of letting
`set -e` end the script silently.

## [NOTE] N1 — Numbering

The PDF says INC-0014; that number is Day 12's tier-2 rollback. Today's is **INC-0015**.

## [NOTE] N2 — `helm` provider 3.x

The PDF's warning is correct and current: `kubernetes = { … }` with an equals sign, `set`
as a list of objects. `versions.tf` requires terraform ≥ 1.9 (the provider needs it) and
`130` checks the installed binary's version before touching state. `01-install-tools.sh`
has installed terraform from HashiCorp's apt repo since Day 1; if `terraform version` says
older than 1.9, `sudo apt-get install --only-upgrade terraform`.

## [NOTE] N3 — What the kps `values` diff after import means

kps was installed on Day 1 with chart defaults and upgraded on Day 8 with
`-f k8s/kps-values.yaml --reuse-values` (and again on Day 12 for the fan-out), so the
release's user-supplied values *are* the file — `helm get values kps -n monitoring` should
match it line for line. Any `~ values` the plan shows on kps is therefore whitespace,
key ordering, or comments (Helm stores the parsed map, not the file): apply once, a no-op
upgrade (revision +1), and the next plan is clean. If a key differs, someone changed the
cluster without the file, and today's rule applies for the first time: fix the file, not
the cluster — or, if the cluster is right, fold it into the file and apply.

## [NOTE] N4 — The first plan wanted to delete a label Helm put there

Post-import, three namespaces showed `- "name" = "monitoring" -> null`. Helm's
`--create-namespace` stamps `name: <ns>` on namespaces it creates; `payments` (kubectl,
Day 2) has none. Nothing selects on the label, so applying would have broken nothing —
and that is precisely the kind of "harmless" diff that teaches the wrong reflex. The label
is now declared in `namespaces.tf`. The rule in one line: *a plan that removes something
you did not know existed is a question, not a cleanup.*

## [NOTE] N5 — The plan says *which*, git says *what*

The helm provider stores `values` as one string, so a one-key change (`repeat_interval:
4h -> 6h`) shows in the plan as the whole map redrawn `-`/`+`, with the changed key nowhere
near the top. The plan is authoritative for *which release, how many, create/change/destroy*;
`git diff k8s/*-values.yaml` is where the change is readable. `131` prints both.

## [NOTE] N6 — The second change through Terraform was a real one

While reading the import's output, Fluent Bit showed `RESTARTS 10`, all clean exits: the
chart's default 1-second probe timeout, and an HTTP server that shares its event loop with
the HEC output, so under the day's log volume the kubelet killed it every ~40 minutes —
no alert, no ticket, log shipping paused for a few seconds each time. The fix (probe
`timeoutSeconds: 5`, in the *template*) went edit → plan → apply → commit, and is on the
Day 14 list as a silent platform incident with verification pending ("no restarts by
tomorrow"). The first day of IaC ended with the code fixing something the commands never
recorded.

## [NOTE] N7 — `grep -q` on the right of a pipe, under `pipefail`

The checkpoint reported the `repeat_interval` commit missing while `git log` plainly showed
it. `git log … | grep -q` — `-q` exits on the first match, git is still writing, git dies of
SIGPIPE (141), `pipefail` makes the pipeline false. Interactive shells do not set `pipefail`,
so testing by hand "works". Rule: `grep -q` on a *file* is fine; on the left of a pipe use
`grep -c` (reads to EOF) or a temp file. Fourth shell lesson of the series, after `set -e`
with `$(…)`, `kubectl auth can-i | grep`, and the heredoc-vs-pipe stdin fight (B7).

---

## Verified as correct

Provider sources and constraints (`hashicorp/kubernetes ~> 2.35`, `hashicorp/helm ~> 3.0`),
the pinned `config_context` idiom, the `namespace/name` import ID format for `helm_release`,
`-detailed-exitcode` semantics, the ownership boundary (platform = Terraform, application =
pipeline), the `repeat_interval` change as the worked example, and the drift injection
command (with `--version` added, D2).
