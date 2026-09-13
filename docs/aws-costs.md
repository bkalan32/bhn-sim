# AWS costs — the rules before the first `terraform apply` (Day 14, for week 3)

Written before anything exists in the account, so week 3 has no surprises. Cloud cost
awareness is an operational KPI; the discipline below is the job, not the lab.

## What bills, and how fast (US regions, list prices — re-check the pricing pages on Day 15)

| Thing | Rate | A day of forgetting it |
|---|---|---|
| **EKS control plane** | ≈ $0.10 / hour per cluster (standard support) | ≈ $2.40 |
| **EKS extended support** | ≈ $0.60 / hour once a Kubernetes version leaves standard support | ≈ $14.40 — the trap: an old version pin costs 6× |
| **Worker nodes** (2 × t3.medium, on-demand) | ≈ $0.042 / hour each | ≈ $2.00 |
| **NAT gateway** | ≈ $0.045 / hour **plus** ≈ $0.045 / GB processed | ≈ $1.10 + data — *the classic silent bill*: it is created by every "quick VPC" tutorial and deleted by none |
| **Elastic IP** (unattached) | ≈ $0.005 / hour | ≈ $0.12 — small, and the one that survives `terraform destroy` when it was made by hand |
| **EBS** (gp3, node root volumes) | ≈ $0.08 / GB-month | cents |
| **ECR** | ≈ $0.10 / GB-month stored | cents for five small images |
| **CloudWatch** (Day 17) | logs ingested ≈ $0.50 / GB; custom metrics ≈ $0.30 / metric-month; first 10 alarms free | the lab's volume: cents — unless a log group is set to *never expire* |
| **Data transfer out** | first 100 GB / month free | nothing, at lab volume |

Rough week, played by the rules below: **a few coffees**. The same week with a cluster and a
NAT gateway left running from Tuesday to Sunday: **~$40** — a month of it, **~$170**.

## The lab rules (in this order, non-negotiable)

1. **Budget alarm before anything else** — Day 15's first task, before the first VPC. AWS
   Budgets: a monthly budget of $20 with alerts at 50 / 80 / 100 % *forecast*, to an email
   you read. Plus a CloudWatch billing alarm as the second, independent signal (billing
   metrics live in `us-east-1` only). Two detectors for the same fault, like Day 5.
2. **Everything through Terraform**, nothing by hand in the console — so `terraform
   destroy` reliably removes it. A resource created by clicking is invisible to `destroy`
   and bills forever. The drift check from Day 13 applies to the account the same way.
3. **Smallest viable nodes**: two `t3.medium` (or one `t3.large`), Spot where the exercise
   tolerates a reclaim. The platform layer ran on a laptop for two weeks; it does not need more.
4. **No NAT gateway unless a step needs it**, and never overnight. Private subnets with NAT
   are the production pattern; for the lab, public subnets with security groups or a
   NAT *instance* is the cost pattern. Whichever is chosen, it is in the Terraform and
   destroyed with the rest.
5. **Nothing left running overnight** — create in the morning, learn, destroy before you
   stop for the day (Day 16 is literally titled *create, learn, destroy*). The rebuild is
   `terraform apply` plus the pipeline, which is the point of Day 13.
6. **Tag everything** `project=bhn-sim`, `day=<n>` so Cost Explorer can answer "what did
   Day 16 cost?" on Day 20 — and so an orphan is findable.
7. **Check the bill every morning** (Billing → Bills, or `aws ce get-cost-and-usage` for
   yesterday) as part of the morning routine, next to `up.sh`. A surprise found on day 2 is
   a coffee; found at month end it is a phone call.

## What to write down as you go

`docs/aws-costs.md` gets a row per day in week 3: date, what existed (cluster? nodes? NAT?),
hours it ran, yesterday's cost from the console. The Day 20 write-up quotes this table —
"the whole cloud week cost $X" is a sentence a hiring manager remembers.

| Day | What ran | Hours | Cost (console, next morning) | Notes |
|---|---|---|---|---|
| pre | **found on Day 15:** a stopped t2.xlarge (`bhn-practice`, 1 Sep) + its 30 GB volume, three unattached EIPs, one KMS key — all in us-east-1 | 1–10 Sep | **$0.51/day, $5.10 total** | $0.36 of it was three public IPs attached to nothing. Released, terminated, key scheduled (17 Sep). `155` now sweeps every region |
| 15 (9 Sep) | VPC + 1 NAT + 5 ECR repos, no images; destroyed at night | ~1.5 h NAT | (`154 --row 15`) | the VPC's first round trip: apply, 90 min, destroy, verified empty |
| 15 (10 Sep) | VPC + 1 NAT + 5 ECR repos with the five kind images | from ~15:00 CT | (`154 --row 15` on the 11th) | DNS relay fixed, images pushed as the bytes kind runs |
| 16 | EKS (control plane $0.10/h) + 2 × t3.medium SPOT (~$0.013/h each) + NAT + 1 EBS GiB + CloudWatch ingest; NLB for ~5 min; destroyed the same day | ~3 h (22:09Z–01:xxZ) | (`154 --row 16` on the 12th) | estimate ≈ $3–4; anything above $5 means something outlived the teardown — `155` |
| 19 | the final game day: EKS (control plane + 2 × t3.medium SPOT) + NAT + EBS + CloudWatch ingest/Insights queries; warm start in the morning, torn down by dinner (`167 --all`) | ≈3.5 h (18:24Z → ≈21:50Z) | **$3.50 (estimate; see the dated rows)** | estimate ≈ $3–4 (Day 16's shape); Insights queries are $0.005/GB scanned — megabytes; **the week's total** goes here too |
| 17 (11 Sep) | EKS kept up overnight from Day 16 for Day 17/18's work on it ("kept everything up so we can start day 18"), torn down on Day 18 | ≈4 h EKS + NAT | **$1.49** (11 Sep, Cost Explorer: EC2-Other $0.86, EKS $0.38, KMS $0.10) | the NAT and EBS billed while nothing ran — the leftover shape 155 exists for |
| 18 (12 Sep, kind only) | nothing in AWS until the evening's warm start | 0 | (in the 12 Sep figure below) | |
| 19 (12 Sep) | see the row above | ≈3.5 h | **$3.50 (estimate — Cost Explorer showed $0.05 for 12 Sep at 23:30Z, KMS only; the real figure lands on the 13th: `154 --row 19`)** | replace this cell when the number is in; anything above $5 means something outlived `167 --all` |
| 20 | destroy, final bill | 0 | — | the week's total below |

**By date, as Cost Explorer reported it on the evening of 12 Sep** (`./scripts/154-aws-cost.sh`; the
lab's days do not line up with UTC dates, which is why the per-day rows above carry the dates):

| date | total | top lines |
|---|---|---|
| 9 Sep | $0.52 | VPC (NAT) $0.36 — the last day of the pre-Day-15 leftovers plus Day 15's first NAT hours |
| 10 Sep | $1.99 | EKS $1.00, EC2-Other $0.46, VPC $0.34 — Day 16's cluster |
| 11 Sep | $1.49 | EC2-Other $0.86, EKS $0.38 — the cluster kept overnight into Day 17/18 |
| 12 Sep | $0.05 (partial) | KMS only so far; Day 19's ≈$3.50 arrives on the 13th |

**The week's total: ≈ $7.6** ($4.07 reported for 9–12 Sep + $3.50 estimated for the game day) —
call it **about eight dollars** for a cloud week with two full EKS days, three teardowns and
one night of leftovers. The sentence for the write-up: *the whole cloud week cost less than
ten dollars, and the two things that cost money while nothing ran were a NAT gateway and an
EBS volume nobody destroyed — which is why the teardown ends with a sweep of every region.*
Final figure: re-run `154 --row 19` on the 13th and correct the two cells above.

