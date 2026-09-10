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

---

## Verified as correct

The order (guardrails → identity → state → network → images) and its reasoning; SSO over
long-lived keys; `use_lockfile` replacing DynamoDB; the public-access block as
non-negotiable; the module choice for the VPC; the public/private/NAT explanation; the
single-NAT trade and the instruction to write it as a comment; the subnet role tags and
the incident they prevent; `force_delete` and `scan_on_push` on ECR; "destroy tonight if
not continuing"; the daily cost look.
