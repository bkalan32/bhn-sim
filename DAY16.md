# Day 16 — EKS: Create, Learn, Destroy

Adapted from `day16eks.pdf`. Changes in **[CORRECTIONS-DAY16.md](CORRECTIONS-DAY16.md)**.

> The PDF's `eks.tf`, applied as written against module v21, produces a cluster whose nodes
> never go Ready (v21 installs no add-ons unless you declare them), an output that does not
> exist (`module.eks.name`), and a Fluent Bit that cannot write to CloudWatch (pods no
> longer borrow the node's role — the IMDS hop limit is 1). All three were checked against
> the module's source, not the PDF's memory, and fixed. Beyond that: the cluster gets its
> own Terraform root so the $4/day layer can come and go without the $1/day one; the two
> pods that need AWS get **Pod Identity**; two t3.mediums get prefix delegation so the
> platform actually fits; and the drill is **INC-0018**. Region: `us-east-2`, as always.

---

## What we're building today, and why — read this first

**Create, learn, destroy is the skill, not a compromise.** A full environment from code,
used for a day and removed with a script that proves it is gone — that is how strong
teams do testing, training and game days, and being the person who can conjure and
remove one is worth a lot on day one of a job.

**The cluster, by module.** `infra/aws/eks` is ~50 resources you will never hand-write:
the control plane, a node group, IAM roles, security groups, an OIDC provider, add-ons.
Three decisions in the file matter and are comments there: nodes in *private* subnets
with a *public* API endpoint (the standard starter posture — pods have no public IPs, you
reach the API from your laptop, the nodes reach out through yesterday's NAT); **SPOT**
capacity (a steep discount for the risk of a two-minute reclaim — free money for a lab,
and if it happens mid-drill you get to watch Day 2's two replicas earn their keep); and
**two nodes**, because a single node hides every scheduling behaviour worth learning.

**The Day 13 payoff.** `infra/aws/platform` is `infra/local` with three differences, each
a comment where it lives: the context (`aws-lab`), Fluent Bit's backend (CloudWatch —
Splunk is on the laptop), and an overlay that stops scraping a control plane you don't
run. Same values files, same chart versions, from a local cache. No imports this time;
the cluster is empty. Notice how it feels next to week 1's command-by-command install.

**The services from ECR, unchanged.** `k8s/aws/` is generated from `k8s/`: the image
line becomes the ECR URL with the tag kind runs; `diff -r k8s k8s/aws` is the whole
difference between the two clusters. The bot, the remediator, the alert routing, the
drill — the same scripts, with one environment variable pointing them at the cloud.

**The differences are the syllabus.** Six of them (the PDF lists five; the sixth bit
while building the cluster), each proven by a command and written in your words.

**Then the meter stops.** In the order that doesn't hang, verified in every region.

Budget: ~3 hours, of which ~35 minutes is waiting for AWS. Cost: ~$3–4 for the hours it
exists — which is why it doesn't exist overnight.

---

## Before you start

`docs/morning.md` — the whole routine, including step 5 (`aws sso login`, `155`, `154 --row 15`
for yesterday's number, `152 status`). Then today's files:

```bash
cd ~ && rm -rf /tmp/day16 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day16.zip').extractall('/tmp/day16')"
cp -r /tmp/day16/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/infra/aws/platform/tf.sh
cd ~/bhn-sim && git status --short
```

The env root must be up (`152 status`: one NAT, five repos with images). If you destroyed it:
`152 plan` → `apply` → `153` first (~8 min).

Keep kind running all day: `163` reads `secret/ai-keys` from it and `162 status` compares
chart versions across the two clusters. The load generators on kind can stay off.

## Step 1 — The cluster (terminal 1)

```bash
./scripts/160-eks.sh plan
```

Read the summary by category: one `aws_eks_cluster`, one `aws_eks_node_group`, five
`aws_eks_addon`, IAM roles (cluster, node, two for pods), security groups, an OIDC
provider, a KMS key, a log group, an access entry, two pod-identity associations. ~50.

```bash
./scripts/160-eks.sh apply           # 10–15 min; it runs 161 at the end
```

**While it builds — read this.** *Why add-ons had to be declared:* module v21 hard-codes
`bootstrap_self_managed_addons = false`; a cluster with no `addons` block has no CNI, so a
node joins, gets no pod network, and sits NotReady forever — the PDF's file does this.
*Why Pod Identity:* two pods need AWS permissions — the EBS CSI driver (the incident-bot's
volume) and Fluent Bit (CloudWatch). The old answer, "put the policy on the node role",
stopped working when the module dropped the instance-metadata hop limit to 1: a pod cannot
reach the node's credentials any more, and that is deliberate — a compromised pod should
not inherit the node's powers. Pod Identity gives each *service account* its own role.
*Why prefix delegation:* each pod gets a real VPC IP; a t3.medium's ENIs hold 17 of them,
and the platform plus services is ~30. Prefix delegation hands out /28 blocks; managed
node groups then compute max-pods themselves. *What "spot" means at 3 AM:* a two-minute
notice, a node gone, a Deployment rescheduling — the same thing you'll see in step 4.

`161` (run by `apply`) writes context **`aws-lab`** — exec auth, a fresh SSO token per
call — and leaves your **current-context alone**. Two clusters now share one kubeconfig.
Every lab script pins its context; you say `--context aws-lab` or `KUBE_CONTEXT=aws-lab`
every time. `kubectl config current-context` before anything destructive, forever. Expect:
2 nodes Ready, SPOT, two AZs, **max-pods 110** (prefix delegation), five add-ons ACTIVE,
two pod-identity associations, and a `kube-system` with no apiserver in it.

## Step 2 — The platform layer, from the Day 13 code

```bash
./scripts/162-eks-platform.sh plan     # namespaces first (a Secret needs a home), Grafana secret, then the plan
./scripts/162-eks-platform.sh apply    # ~5 min; applies exactly the saved plan
```

Five releases, same versions as kind (the script says so). `status` afterwards: every pod
Running, **no Prometheus target down** (the control-plane scrapes are off — on kind those
were the "false positives"; here they'd be honest and permanent), and the CloudWatch log
group not yet — nothing in `payments` has logged.

## Step 3 — The services, the ticket layer, the drill

```bash
./scripts/163-eks-deploy.sh
```

It renders `k8s/aws/` (look at `diff -r k8s k8s/aws` once — image lines, and kind's
NodePort doors gone), copies `secret/ai-keys` from kind to EKS through a pipe (no file),
applies the five services + the alert rules + the Tempo datasource + the dashboards, waits
for rollouts, proves the PVC is **Bound** (an EBS volume, made by the CSI driver through
Pod Identity), wires the bot and remediator with `100` and `120` under
`KUBE_CONTEXT=aws-lab`, and checks: four targets UP, the bot and remediator answering, the
Alertmanager route live, CloudWatch streams appearing. The logs collector will say **not
configured** — Splunk is on the laptop; that gap is deliberate and part of the drill.

Traffic and Grafana, two more terminals:

```bash
./scripts/164-eks-traffic.sh                                   # terminal 2: both generators via port-forwards on :18000/:18010
KUBE_CONTEXT=aws-lab GRAFANA_PORT=3001 ./scripts/06-grafana.sh # terminal 3: the EKS Grafana on :3001 (kind keeps :3000)
```

Open http://localhost:3001 → Platform Overview. Same dashboards, a cloud's data. Then:

```bash
./scripts/165-eks-drill.sh
```

The Day 10 dependency drill, on EKS. Grade it against INC-0009: same cause, lower
confidence, and does the record say *why* a source is missing? At the end the script runs
the same incident as a **Logs Insights** query — the Day 3 Splunk search, other pane.
Write `incidents/INC-0018.md` (template shipped), row 0018 in `docs/ops-kpis.md`, Eval 7
in `docs/ai-eval.md` (stub shipped).

## Step 4 — What is different up here

```bash
./scripts/166-eks-differences.sh          # ~12 min; --quick skips the two that wait on AWS
```

Six differences, each proven by a command whose output lands in `docs/eks-notes.md`.
Two of them *do* things: scale the node group to 3 and back (watch which pods move, and
which don't), and turn `activation` into a **LoadBalancer** — a real NLB, public DNS, a
`curl` from the internet to your lab service — then back, with the deletion verified
(the leftover NLB is *the* classic orphan: it bills and it blocks the VPC destroy). Then
the part that is yours: **one line in your words** for each row of the table at the top
of `docs/eks-notes.md`. The checkpoint counts them.

## Step 5 — Destroy, and verify the destroy

```bash
./scripts/167-eks-teardown.sh             # keeps VPC/NAT/ECR for tomorrow (~$1.10 overnight)
./scripts/167-eks-teardown.sh --all       # or: nothing bills by the hour afterwards
```

Order: LoadBalancer Services reverted → platform root → EKS root (~10 min) → the
CloudWatch group Fluent Bit created → **`155` across every region**. The context `aws-lab`
is removed from your kubeconfig (a context to a dead cluster is a trap).

---

## Wrap

```bash
git add -A && git commit -m "Day 16: EKS create-learn-destroy — platform + services unchanged, INC-0018 on the cloud, six differences with evidence"
./scripts/168-checkpoint-day16.sh
```

The cost row waits for tomorrow's `154 --row 16`. Expect $3–4; more means something
outlived the teardown, and `155` says what.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `160 plan`: `no lab VPC found` | the env root is destroyed — `152 plan` → `apply` first |
| `160 apply` fails part-way | normal for a 50-resource apply (a timeout, a spot capacity blip): `160 plan` → `apply` again; it converges |
| nodes never Ready | `161`'s add-on list: `vpc-cni` not ACTIVE. `160 status`; `kubectl --context aws-lab describe node \| grep -A5 Conditions` |
| `max-pods 17` in `161` | prefix delegation didn't take; pods will go Pending "Too many pods" — scale to 3 (`166` step 1) or `aws eks describe-addon --addon-name vpc-cni` for the config |
| `162 apply`: a release fails | Pending pods: `kubectl --context aws-lab get pods -A \| grep -v Running`, then `describe`. `Insufficient cpu/memory` → the 3rd node; then `162 plan && apply` |
| `162 status`: a target down | right after apply, still starting; a minute later it's real — `promql 'up == 0'` names it |
| PVC `Pending` in `163` | the EBS CSI add-on or its pod identity: `kubectl --context aws-lab -n kube-system logs deploy/ebs-csi-controller -c ebs-plugin \| tail`; `aws eks list-pod-identity-associations` |
| `ImagePullBackOff` | `153 --verify`: is the tag there, is it `linux/amd64`? nodes pull with their role, no secret needed |
| `exec format error` | an arm64 image slipped in (impossible from WSL x86; possible from a Mac) — `153 <svc>` rebuilds it |
| no CloudWatch streams | `kubectl --context aws-lab -n logging logs ds/fluent-bit \| grep -iE 'credential\|denied'` — Pod Identity: is the association there, is the SA named `fluent-bit`? |
| `165`: no ticket after 6 min | is `164` running? No traffic → no error *rate* → no alert. `kubectl --context aws-lab -n payments logs deploy/incident-bot` |
| `166` step 2: no NLB hostname | `describe svc activation` events — subnet tags (`role/elb`) missing, or the CCM is still working (3 min) |
| `167` / `160 destroy` hangs on the VPC or an SG | an orphan NLB or ENI from a Service not reverted — `160 status` counts load balancers; `155` names ENIs; delete in the console; destroy again |
| `kubectl` acted on the wrong cluster | `kubectl config current-context`. The lab scripts can't (pinned); bare `kubectl` can. Say `--context` every time |
| spot node vanished mid-drill | spot working as priced. Watch the Deployment reschedule; `166` step 1's note |
| `aws` says token expired | `aws sso login --profile lab` — kubectl on `aws-lab` needs it too (exec auth) |

---

## What's next

Day 17: the New Relic account from Day 1 wired in for hosted observability alongside the
self-run stack, and the start of the operational knowledge base the AI layer will draw on.
Carry-over from today: a CloudWatch Logs collector for the bot, so an EKS ticket has three
sources again.
