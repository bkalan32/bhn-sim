# EKS notes — what is different when AWS runs Kubernetes (Day 16)

The same platform, the same five services, the same drill — on a cluster you did not
build node by node. The differences are the day's syllabus. Each row: the evidence a
script produced (`scripts/166-eks-differences.sh`, block at the bottom), and **one line in
your words** — write it as you would say it to a colleague on their first EKS on-call.

| # | Difference | In my words (one line) | Where it bites at work |
|---|---|---|---|
| 1 | **Nodes are cattle with bills.** EC2 instances with an instance type, an AZ and a capacity type (SPOT: reclaimable with two minutes' notice). Scaling the node group adds a node that fills only with *new* pods; scaling down drains one and its pods reschedule. | Every node is a bill and a rumour: mine got a spot rebalance warning 90 s after birth, AWS launched a replacement, drained the old one, and I never dropped below two — scale up fills the new node with daemonsets only, scale down drains one and the two-replica services just move. | the 3 AM "node NotReady" page that is a spot reclaim working as priced; the budget line that is a node group nobody scaled back |
| 2 | **LoadBalancer Services mean money and exposure.** `type: LoadBalancer` provisions a real NLB in the public subnets (Day 15's `role/elb` tag) with a public DNS name — ~$0.02/h plus per-LCU, and your service is on the internet. Reverting deletes it; verify, because a leftover NLB bills and blocks the VPC destroy. | `type: LoadBalancer` is a purchase and a door: nine minutes from patch to a public NLB answering `curl` from the internet to deleted-and-verified — always check `elbv2` is back to zero, because an orphaned one bills and blocks the VPC destroy. | orphaned load balancers are one of the most common cloud cost leaks and exposure incidents |
| 3 | **CloudWatch is the second pane of glass.** Fluent Bit ships the same JSON to `/bhn-sim/containers`; Logs Insights queries `app.*` fields. It overlaps Splunk/Grafana for search and counts; it does not do PromQL, SLO burn rates, or route into the bot — which has no CloudWatch collector yet (its logs source is "not configured" on EKS). | Fluent Bit shipped the same JSON to CloudWatch with no credential in the config (Pod Identity); Logs Insights answered the Day 3 question in one query (`fraud_service_timeout 894`) — but the bot can't read it yet, so ask CloudWatch for 'which reason', Grafana for 'how bad', and know which one you're in. | "which system answers this question" is an on-call skill; real AWS shops run both |
| 4 | **The control plane is not yours.** No `kube-apiserver`/etcd/scheduler pods to describe; the chart's scrapes of them are switched off (`kps-values-eks.yaml`) or they would be TargetDown forever. Health arrives as EKS status and the `/aws/eks/bhn-sim/cluster` log group. | There's no `kube-apiserver` pod to describe and no scheduler to scrape — AWS runs them, the chart's scrapes of them are switched off, and 'the API is slow' becomes a look at EKS status and `/aws/eks/bhn-sim/cluster`, not an ssh. | the runbook says "check the EKS console / AWS Health", not "ssh to the master" |
| 5 | **IAM is the new RBAC boundary.** Your SSO role is cluster-admin through an *access entry* (not `aws-auth`). Pods that need AWS — the EBS CSI driver, Fluent Bit — have their own IAM role via *Pod Identity*; nothing borrows the node's role (IMDS hop limit is 1 since module v21). | My SSO role is admin through an access entry, not `aws-auth`; the two pods that talk to AWS (EBS CSI, Fluent Bit) each have their own IAM role via Pod Identity, and nothing borrows the node's — so 'AccessDenied in a pod' is an IAM question first. | "the pod gets AccessDenied" is an IAM question, not a Kubernetes one |
| 6 | **Pod density is an IP-address problem.** Every pod gets a real VPC IP from an ENI; a t3.medium holds 17 pods that way. Prefix delegation (vpc-cni config) raises it to 110. Without it the platform alone would not have fit on two nodes. | Pods eat VPC IPs: a t3.medium holds 17 without prefix delegation and I was going to run 30 — with it, 110 per node; 'Pending — Too many pods' on a node with spare CPU is an IP problem, not a capacity one. | "Pending — Too many pods" on a node that is half idle |

## Also different, in passing

- **Storage.** kind's local-path provisioner was invisible; on EKS a PVC needs the EBS CSI
  add-on, the volume lives in ONE availability zone, and a pod with a volume can only
  reschedule into that AZ (the incident-bot, if its node's AZ loses capacity).
- **No default StorageClass** (EKS ≥ 1.30): a PVC with no class waits forever. The
  platform root now ships a default gp3 class (`storage.tf`); the incident-bot's claim
  bound only after it existed (B12).
- **The API service proxy is a network path.** `kubectl get --raw …/proxy` — every lab
  tool's route to Prometheus, Alertmanager, the bot — needs the control plane allowed
  into the nodes on those ports. One security-group rule (`eks.tf`, B13); on kind, nothing.
- **Two clusters, one kubeconfig.** `kubectl config current-context` before anything
  destructive; every lab script pins `--context`; the EKS scripts export
  `KUBE_CONTEXT=aws-lab` themselves.
- **Time.** kind: cluster in 60 s. EKS: control plane ~8 min, node group ~3, destroy ~10.
  The create-learn-destroy loop is 25 minutes each way; that is the shape of ephemeral
  environments everywhere.
- **Same.** The values files, the alert rules, the dashboards, the bot, the remediator's
  policy, the drill, the ticket — zero application or manifest changes beyond the image
  line. That portability is Kubernetes doing its job.

## Papercuts — what broke because it was AWS (Day 19, game day 2)

The first-week friction at a real job, pre-felt. Each one a line: what happened, what it
cost in minutes, what the fix was, and whether it is now a script or a runbook line.

| # | what broke | minutes lost | fix | now in |
|---|---|---|---|---|
| 1 | _e.g. a tool ran against kind because `KUBE_CONTEXT` was not exported in that shell_ | | | |
| 2 | _e.g. the bot's logs collector said "not configured" until the Pod Identity association existed (160's plan carries it since Day 19)_ | | | |
| 3 | _e.g. stale port-forwards from a previous 164 (`pkill -f port-forward`)_ | | | |
| 4 | | | | |

**Closed on Day 19:** the third collector. Splunk is a container on the laptop; on EKS the
bot now reads CloudWatch Logs Insights through Pod Identity (`enrich.py`, `LOGS_BACKEND=
cloudwatch`; `infra/aws/eks/pod-identity.tf`, `payments/incident-bot`) — the same rows the
Splunk collector returns, so the hypothesis prompt never knows which cloud it is on. The
copilot's `search_logs` speaks SPL; on EKS the bot translates the subset it uses
(`key=value | stats count by | sort | head | table`) and refuses the rest with a reason.
