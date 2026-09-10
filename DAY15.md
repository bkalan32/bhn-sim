# Day 15 — AWS Foundations, Guardrails First

Adapted from `day15awsfoundations.pdf`. Changes in **[CORRECTIONS-DAY15.md](CORRECTIONS-DAY15.md)**.

> The PDF is written for a Mac in the Philippines: `brew`, Apple Silicon's arm64 trap,
> `ap-southeast-1`, hard-coded AZ names, and "you are on Terraform ~1.9". You are on WSL,
> x86, in the US Central zone, on Terraform 1.16. Region is one variable (`us-east-2`);
> the bucket name is generated, not guessed; AZs come from a data source; every "confirm
> in the console" is verified through the API instead; and the "verify with your eyes"
> after a destroy is a script. Nothing today costs more than pennies — except the NAT
> gateway from Step 4 onward, which is why Step 4 ends with a decision.

---

## What we're building today, and why — read this first

**The order is the lesson.** Money guardrails, then identity, then state, then network,
then images. Everyone who has been billed for a forgotten NAT gateway learned it the other
way round. Nothing today is expensive; today's work is what makes tomorrow (EKS) safe.

**Guardrails first** — a $20 budget with alerts at 50 % and 80 %, free-tier alerts, MFA on
root, and then root goes in a drawer. Ten minutes of clicking, done once. `150` then
*proves* they exist through the API, because "I think I set the budget" and "the budget
exists" are different sentences at month end.

**Identity the modern way** — IAM Identity Center (SSO) with short-lived credentials, not
a long-lived access key. Sessions expire; that's the feature. Leaked long-lived keys are one
of the most common real-world cloud incidents, and the role you're preparing for lives
downstream of exactly those.

**Remote state** — Day 13's state lived on the laptop, flagged as a shortcut. In a team,
state is shared and locked. Terraform ≥ 1.10 locks in S3 itself (`use_lockfile`), so no
DynamoDB table — you're on 1.16, so this works as written. The bucket is versioned (every
state write is an undo point), private (non-negotiable for any bucket, ever), encrypted.

**The VPC** — kind gave you networking for free; AWS makes you choose it, and the choices
bill. Say the shape in one breath: *load balancers live in public subnets; nodes and pods
live in private subnets and reach the internet outbound through the NAT gateway.* That is
the standard production posture and the source of a whole genre of incidents ("the pods
can't reach the payment partner's API"). One NAT instead of one per AZ is the lab's
deliberate cost/availability trade, written as a comment in the file — reading
infrastructure code and spotting those trades is an operations skill in itself.

**ECR** — kind loaded images straight from the Docker daemon; EKS pulls from a registry.
Five repositories, scan on push, and a lifecycle policy so pushes don't accumulate forever.
The images are built `--platform linux/amd64` explicitly, tagged with exactly what kind runs.

**Then the meter.** From Step 4 the NAT bills ~$1.10/day whether or not anything uses it.
If you are not continuing to Day 16 tomorrow, `destroy` tonight and re-apply when you
resume — a five-minute round trip, and exactly the muscle week 3 is about.

---

## Before you start

`docs/morning.md` as usual (the platform on kind keeps running; today doesn't touch it
until the ECR push reads the image tags from it). Then install today's files:

```bash
cd ~ && rm -rf /tmp/day15 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day15.zip').extractall('/tmp/day15')"
cp -r /tmp/day15/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh
cd ~/bhn-sim && git status --short
```

Budget: ~1.5 hours (30 min of it console clicks in Steps 1–2), or under an hour if you did
the guardrails last night. Cost: cents today; ~$1/day for the NAT while the VPC exists.

---

## Step 1 — Billing guardrails (console, as root, nearly the last time)

Sign in to https://console.aws.amazon.com as the **root** user.

- [ ] **Budget:** Billing and Cost Management → Budgets → Create budget → *Customize* →
      Cost budget → Monthly → amount **$20** → alert thresholds **50 %** and **80 %** of
      *actual* → your email. This is the smoke detector.
- [x] **Free Tier alerts:** Billing → *Billing preferences* → *Alert preferences* → enable
      *Receive AWS Free Tier alerts* (the API cannot read this one — tick it here when done: `[x] Free Tier`).
- [ ] **Cost Explorer:** Billing → Cost Explorer → *Launch* (once; data appears within 24 h).
- [ ] **Root MFA:** IAM → *Add MFA* for the root user (an authenticator app is fine). Then sign out of root.

## Step 2 — Identity (console once, then WSL)

- [ ] Console → **IAM Identity Center** → Enable → region **us-east-2**. Users → *Add user*
      (yourself, your email) → accept the invitation email, set a password + MFA.
      *Permission sets* → create **AdministratorAccess** (predefined). *AWS accounts* → your
      account → *Assign users* → you → AdministratorAccess. Copy the **AWS access portal URL**
      from the dashboard.

```bash
./scripts/150-aws-guardrails.sh --install     # AWS CLI v2 in WSL (not brew)
./scripts/150-aws-guardrails.sh --sso         # aws configure sso: session 'lab', the portal URL, us-east-2, profile 'lab'
./scripts/150-aws-guardrails.sh               # verify: SSO identity, root MFA, budget, Cost Explorer, terraform >= 1.10, buildx
```

Expect `account <id> as arn:…:assumed-role/AWSReservedSSO_AdministratorAccess_…`, root MFA
enabled, the budget with two thresholds. Anything `warn` is a console step not done.

## Step 3 — Remote state

```bash
./scripts/151-aws-state.sh
git add infra/aws .gitignore && git commit -m "Day 15: S3 state bucket (versioned, private, S3-native lock); env root"
```

Creates the bucket (`bhn-sim-tfstate-bk-<4 hex>`), proves versioning / public-access
block / encryption through the API, writes the name into `infra/aws/env/backend.hcl` (and
`platform/` for tomorrow — committed: configuration, not a secret), and inits the env root
against S3. The bucket root's own state stays local and gitignored.

## Step 4 — The VPC (the meter starts here)

```bash
./scripts/152-aws-vpc.sh plan
```

Read the summary: exactly **one** `aws_nat_gateway` and one `aws_eip`, two public + two
private subnets across two AZs, the `kubernetes.io/role` tags, five `aws_ecr_repository`
(+ five lifecycle policies). Roughly 25–30 resources. Then:

```bash
./scripts/152-aws-vpc.sh apply
```

It applies the saved plan (two to three minutes — the NAT is the slow one) and proves the
result through the API: the four subnets with their tags, one NAT with its public IP, five
repos. **From this moment the meter runs.**

## Step 5 — The images

```bash
./scripts/153-aws-ecr-push.sh
./scripts/153-aws-ecr-push.sh --verify
```

Logs in to ECR with a 12-hour token from your SSO session, then for each of the five
services builds `--platform linux/amd64` and pushes with the tag the service runs on kind
right now (`activation:33`, `egift:0.1`, …) plus `latest`. First push is slow (every layer
crosses the internet once); the rest reuse layers. `--verify` lists what ECR holds, the
architecture of each newest image, and the scan status — open one report in the console
(Amazon ECR → repository → image → Vulnerabilities): that's where "why is security asking
about our base image" tickets come from.

## Step 6 — Runbook and the bill

The README's **AWS** section is written (login, bucket, apply/destroy, push loop, the
standing rule). Read it once as the stranger at 3 AM. Then:

```bash
./scripts/154-aws-cost.sh
```

Today it will say cents or nothing (Cost Explorer lags ~24 h). Tomorrow morning:
`./scripts/154-aws-cost.sh --row 15` prints the Day 15 row for `docs/aws-costs.md` with the
real number — paste it in, and screenshot Cost Explorer if you want the picture.

## Decision — pausing or continuing?

**Continuing to Day 16 tomorrow:** leave it up (~$1 overnight), commit, checkpoint.
**Pausing for more than a day:**

```bash
./scripts/152-aws-vpc.sh destroy        # VPC, NAT, EIP, ECR repos + images; keeps bucket, SSO, budget
```

It ends with `155-aws-verify-destroyed.sh` — EC2, NAT, EIPs, load balancers, EKS, orphan
ENIs, unattached volumes — because the PDF's own troubleshooting says the stray EIP is the
most common leftover, and a script checks an empty list better than eyes do. Re-apply is
five minutes (`152 plan` → `apply` → `153`).

---

## Wrap

```bash
git add -A && git commit -m "Day 15: AWS foundations — guardrails verified, S3 state, VPC (1 NAT), ECR + amd64 images"
./scripts/158-checkpoint-day15.sh
```

The cost-row check will fail until tomorrow's `154 --row 15` — that's the one line of
the checkpoint that has to wait for the bill.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `aws` says token expired / `no session` | `aws sso login --profile lab` — sessions last hours, not days |
| `150`: root MFA not enabled | the IAM console *as root* → Add MFA; `150` again |
| `150`: NO budget | Billing → Budgets → Create ($20, 50 %/80 % actual); it exists within a minute |
| `151`: bucket name taken | can't happen (random suffix) — if it does, `terraform -chdir=infra/aws/backend taint random_id.suffix` and re-run |
| `151`: `use_lockfile` unsupported | Terraform < 1.10 — you have 1.16; if a different `terraform` is first on PATH, `which -a terraform` |
| `152 plan`: `AccessDenied` | the permission set is not AdministratorAccess, or the session is for another account |
| `152 apply`: two NAT gateways | `single_nat_gateway = false` slipped in — the meter doubled; fix and apply |
| `153`: `exec format error` (tomorrow) | an image built without `--platform linux/amd64` — rebuild that one service: `153 <svc>` |
| `153`: buildx "no builder" | `docker buildx create --name bhn --use` (the script does this) |
| `153`: push very slow | normal on the first push; later pushes reuse layers |
| `154`: Cost Explorer not answering | not enabled yet (Step 1), or the 24-hour lag |
| `152 destroy` hangs on the VPC | an orphan ENI or load balancer — `155` names it; delete in the console; destroy again |
| NAT still billing after destroy | an EIP left allocated — `155` shows it; release it in the console |

---

## What's next

Day 16: EKS by Terraform, the Day 13 platform code applied onto it with only provider
changes, the five services from ECR, one incident drill on a cloud the platform has never
seen (INC-0018) — and destroyed by dinner.
