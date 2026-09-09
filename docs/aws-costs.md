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
| 15 | VPC, ECR, state bucket, IAM — no compute | – | | budget alarm confirmed by email |
| 16 | EKS + 2 nodes, destroyed same day | | | |
| 17 | | | | |
| 18 | | | | |
| 19 | | | | |
| 20 | destroy, final bill | | | |
