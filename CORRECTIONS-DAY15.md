# Day 15 — Corrections Log

Source: `day15awsfoundations.pdf` · Verified 9 September 2026 (build); the AWS side is
verified as the day runs.

---

## [BUG] B1 — Region: `ap-southeast-1` "from the Philippines", hard-coded in four files

**Guide, Steps 2–4:** Singapore, chosen for latency from Manila, written literally into the
provider blocks, the backend block, the VPC's `azs`, and the ECR login URL. From the US
Central zone that is 200+ ms away and the wrong region for every console link. **Substitute:**
**`us-east-2`** (Ohio — N. Virginia prices, less crowded), and it is **one variable**:
`AWS_REGION` in `scripts/lib.sh`, `var.region` in both Terraform roots, `region` in the
generated `backend.hcl`. Nothing else names a region. Changing it later is one line and a
`terraform init -reconfigure`.

---

## [BUG] B2 — It is a Mac: `brew install awscli`, Apple Silicon's arm64 trap

**Guide, Steps 2 and 5.** WSL has no `brew`; `150 --install` uses AWS's official Linux
installer. The "your Mac is almost certainly Apple Silicon, building arm64 images for amd64
nodes — `exec format error`" trap does not apply to an x86 laptop — WSL builds amd64
natively — but `--platform linux/amd64` **stays** in the push loop, explicitly: it costs
nothing, it says the target out loud, and it is the line that saves whoever clones this
repo on a Mac.

---

## [BUG] B3 — "You are on ~1.9 from Day 1; `brew upgrade terraform`"

**Guide, troubleshooting.** Day 1 installed from HashiCorp's apt repo; `130` measured 1.16.0
on Day 13. `use_lockfile` (S3-native locking, Terraform ≥ 1.10) works as written. Both roots
declare `required_version = ">= 1.10"` and `150` checks the binary, so a stale `terraform`
first on `PATH` fails with a sentence, not a backend error.

---

## [BUG] B4 — The bucket name is a guess, and the same name is typed twice

**Guide, Step 3:** `bhn-sim-tfstate-<your-initials>-<random4>` typed by hand into
`backend/main.tf`, then typed again into `env/backend.tf`; "bucket name taken: add
randomness" in troubleshooting. **Substitute:** `random_id` generates the suffix on apply;
`151` reads the name from the backend root's output and writes it into
`infra/aws/env/backend.hcl` and `infra/aws/platform/backend.hcl` (committed — configuration,
not a secret); the roots' `backend.tf` carry only the *key* and `use_lockfile`. One source
of truth, no typing.

---

## [BUG] B5 — AZ names hard-coded

**Guide, Step 4:** `azs = ["ap-southeast-1a", "ap-southeast-1b"]`. Wrong in every other
region, and silently wrong in the regions where a given letter is not available to the
account. **Substitute:** `data "aws_availability_zones"` (opt-in-not-required) sliced to
the first two.

---

## [BUG] B6 — "Confirm in the console" — five times

**Guide, Steps 1, 3, 4, 5, 6:** budget set? MFA on? bucket versioned? NAT exactly one?
images pushed? All "look at the console". **Substitute:** every one that the API can
answer is answered by a script — `150` reads the account summary (root MFA), the budget and
its thresholds, and pokes Cost Explorer; `151` reads the bucket's versioning, public-access
block and encryption back; `152 apply` lists the subnets with their `kubernetes.io/role`
tags and counts NAT gateways and repositories; `153 --verify` reads each image's
architecture and scan findings; `158` re-checks all of it. The one thing the API cannot
read — Free Tier alerts — is a checkbox in `DAY15.md` that the checkpoint looks for.

---

## [BUG] B7 — No lifecycle policy on the ECR repositories

**Guide, Step 5.** `scan_on_push` and `force_delete`, nothing about retention. Jenkins pushed
~30 builds of activation to kind in two weeks; the same habit against ECR accumulates
GB-months forever. **Substitute:** `aws_ecr_lifecycle_policy` per repo — untagged layers
expire after a day, keep the last 10 tagged images.

---

## [BUG] B8 — "Verify with your eyes" after a destroy

**Guide, Step 6 (and Day 16, Step 5):** after `terraform destroy`, look at the console for
instances, load balancers, NAT gateways, EIPs, clusters — and the PDF's own troubleshooting
admits "a stray EIP is the single most common leftover". Eyes are bad at empty lists.
**Substitute:** `155-aws-verify-destroyed.sh` — EC2, NAT, EIPs (attached or not), load
balancers, EKS clusters, lab VPCs, orphan ENIs (the thing that makes a VPC destroy hang),
unattached EBS volumes — exit 1 if anything bills. `152 destroy` ends with it; the morning
routine starts with it.

---

## [BUG] B9 — My B8 had the same blind spot as the PDF: one region (found at Step 6)

`155` checked us-east-2 and said "nothing billing" — twice, correctly — while the account
was paying **$0.51/day** in us-east-1: a stopped t2.xlarge from a first attempt at this lab
(`bhn-practice`, 1 September), its 30 GB volume, **three elastic IPs attached to nothing**
($0.005/h each — AWS bills every public IPv4 since 2024, associated or not) and a KMS key
left from an RDS exercise ($1/month). Ten days, $5.10, a quarter of the budget, invisible
to a script that only looked in the lab's region. It surfaced because `154` prints the last
three days and the 7th–9th were identical and non-zero *before the VPC existed* — reading
the bill, not the console, is what found it. **Fix:** `155` now sweeps every enabled region
for the things that bill while idle (instances, EIPs, volumes, NAT, load balancers, live
customer KMS keys) and fails on any of them; the lesson goes in the README as a rule: *the
lab lives in one region, the bill does not.* Cleanup was three commands: `release-address`
×3, `terminate-instances` (root volume `DeleteOnTermination=True`), `schedule-key-deletion`
(seven-day minimum, by design, cancellable). `docs/aws-costs.md` carries the `pre` row.

---

## [DESIGN] D1 — Tags are the cost-attribution mechanism

`default_tags` on the provider (`project=bhn-sim`, `managed_by=terraform`) — every resource
carries them, so Cost Explorer can group by tag on Day 20 ("what did Day 16 cost?") and an
orphan is findable by tag. `docs/aws-costs.md` rule 6, implemented once instead of per file.

## [DESIGN] D2 — Image tags mirror kind

`153` reads each service's running tag from the kind cluster and pushes with that tag
(plus `latest`). Day 16's `k8s/aws/` manifests are then the kind manifests with the
registry prefix added and nothing else, and "what version is on EKS?" has the same answer
as "what version is on kind?". The PDF's `:0.4` for activation would have been a second,
unrelated version scheme.

## [DESIGN] D3 — Plan is saved, apply applies the saved plan

`152 plan` writes `env.tfplan`; `152 apply` refuses without it. What you read is what gets
applied — the Day 13 habit, enforced.

## [NOTE] N1 — Cost Explorer costs money to ask

Each `ce get-cost-and-usage` call is $0.01. `154` makes two per run. Fine for a daily look;
not fine in a loop. Data lags about 24 hours, so "today's cost" is yesterday's.

## [NOTE] N2 — Numbering, and the "sixteen incidents"

The PDF opens with "sixteen incidents of practice"; the table has seventeen numbered rows
plus sub-rows. Day 16's drill is **INC-0018** (the PDF says 0017).

## [NOTE] N3 — "Splunk is on your Mac"

Splunk is a container on the kind Docker network in WSL. Day 16 sends Fluent Bit on EKS to
CloudWatch exactly as the PDF says; the kind cluster keeps shipping to Splunk.

## [NOTE] N4 — Build error, mine: a nested block on one line (found at Step 3)

`backend/main.tf` had `rule { apply_server_side_encryption_by_default { … } }` on one line.
HCL allows a single-line block only when it holds one *argument*; a nested block must sit on
its own line. `terraform init` refused the root with "Argument definition required". Fixed by
expanding the block; every AWS `.tf` file was then parsed offline. Same class of mistake as
the Day 13 `grep -q`/pipefail one: syntax that reads fine and fails at the first run.

## [NOTE] N5 — The AWS CLI installer starves the VM (found at Step 2)

Unpacking and copying ~250 MB into `/usr/local` on a WSL VM with ~80 MB free drove the
load average to 90 and the kernel to 74 % system time (memory reclaim); the kind control
plane lost its leader-election leases and `kube-scheduler`, `kube-controller-manager` and
the prometheus operator crash-looped until the copy finished. It happened again two hours
later, on Terraform + the 600 MB AWS provider binary. Nothing was wrong with the cluster.

**The fix, applied the same night:** the Day 1 `.wslconfig` gave the VM 4 of the laptop's
20 threads and 10 of 16 GB, with WSL hoarding 6–7 GB of page cache inside that cap. New
file: `processors=8`, `swap=4GB`, `[experimental] autoMemoryReclaim=gradual` (WSL ≥ 2.0
hands idle cache back to Windows). Memory stays at 10 GB — Windows needs the rest. After
the restart: 8 CPUs, 700 MB actually free, memory pressure zero. `up.sh` prints the CPU
count. `153`'s five image builds still run with the load generators stopped.

## [NOTE] N6 — WSL 2.7's DNS relay stalls every Go program (the day's real villain)

Every "TLS handshake timeout", the "Saved plan is stale" detour, and the helm chart
fetches that failed on a link where `curl` answered in half a second — one cause. WSL 2.7
(new since Day 1) points `/etc/resolv.conf` at its own DNS relay, `10.255.255.254`. glibc
(curl, Python, the AWS CLI) is fine with it; Go's built-in resolver, which sends A and AAAA
in parallel, stalls against it, and Go's HTTP client reports a stalled lookup as
"Client.Timeout exceeded while awaiting headers". helm, terraform, every provider: Go.
Proof: `helm pull` of one chart, 2 min 2 s and a timeout; `/etc/resolv.conf` → `1.1.1.1`;
same command, 2.3 s. MTU was ruled out first (a real GET at 1500 pulled 13 KB in 0.5 s);
the `.wslconfig` change is unrelated.

**Fix, in two acts.** Night: `[network] generateResolvConf=false` in `/etc/wsl.conf` plus a
hand-written `resolv.conf`. Morning: with WSL no longer writing the file, **systemd-resolved**
(`systemd=true` since Day 1) took it over — stub `127.0.0.53`, no upstream, *every* lookup
"server misbehaving", curl included. The durable fix is to give resolved its upstream:
`/etc/systemd/resolved.conf.d/lab.conf` with `DNS=1.1.1.1 8.8.8.8`, `systemctl restart
systemd-resolved`. Survives reboots, applies to every program. `up.sh` now tests that a name
resolves rather than reading the address in the file.

## [DESIGN] D4 — A plan that needs GitHub to answer eight times (found, not fixed)

Day 13's `experiments { manifest = true }` makes every plan and apply download all four
charts (index + tgz each) to render them. Even with DNS fixed, one of eight fetches
stalled on a bad evening, a different chart each run, and `terraform apply` of a
one-line Fluent Bit change failed three times. The platform layer's plan should not depend
on GitHub: a local chart cache (charts vendored under `infra/local/charts/` or a
`helm pull` step in `tf.sh` with `repository` pointing at the directory) is the fix, and
Day 16 gets it — the EKS platform root copies this code and inherits the flaw otherwise.
Shelved on the night: Fluent Bit stayed on Splunk's old IP, no logs shipped, Day 15
needed none.

## [DESIGN] D5 — Push the image kind runs, do not rebuild it (found at Step 5)

The first `153` rebuilt each service from `services/<svc>` with `buildx` and called the
result `remediator:28`. Two faults. The small one: `requirements.lock.txt` is generated
(`pip freeze` in `build_service`) and gitignored; remediator's last build was Jenkins's, in
its own workspace, so the directory had none and the build died at `COPY`. The real one:
a rebuild is *a different image wearing the same tag* — today's source, whatever lock file
is on disk — so D2's "what is on EKS is what is on kind" would have been true of the tag
and false of the bytes. `153` now finds the image kind runs in the local Docker daemon
(that is how `kind load` got it), reads its `os/arch`, retags it with the registry prefix
and pushes it unchanged, printing the digest. The four images pushed before the fix were
rebuilds; the rerun replaced them. Building from source (`--platform linux/amd64`, B2)
stays as the fallback for an image the daemon no longer has — and says so with a `warn`,
because that copy is not byte-identical.

## [NOTE] N7 — Fluent Bit restarts are back: 19 in 24 h

Day 13's probe-timeout fix (1 s → 5 s) took restarts to zero for a day. On Day 15 the pod
showed `RESTARTS 19`, the last one at the WSL reset. Two thrash episodes account for some;
not obviously all. Watch it on Day 16 morning: if it climbs with the VM quiet, the probe
window is still too short under load, or the HEC output blocks the event loop longer than
5 s while Splunk is unreachable — and it was unreachable all night (D4).

---

## Verified as correct

The order (guardrails → identity → state → network → images) and its reasoning; SSO over
long-lived keys; `use_lockfile` replacing DynamoDB; the public-access block as
non-negotiable; the module choice for the VPC; the public/private/NAT explanation; the
single-NAT trade and the instruction to write it as a comment; the subnet role tags and
the incident they prevent; `force_delete` and `scan_on_push` on ECR; "destroy tonight if
not continuing"; the daily cost look.
