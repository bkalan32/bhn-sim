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

<!-- evidence:start -->
## Evidence (generated by scripts/166-eks-differences.sh, 2026-09-11T00:23Z)

```
node ip-10-0-11-25.us-east-2.compute.internal  t3.medium  us-east-2a  SPOT  since 2026-09-10T22:21:27Z
node ip-10-0-12-113.us-east-2.compute.internal  t3.medium  us-east-2b  SPOT  since 2026-09-10T22:22:39Z
scaled to 3: 3 Ready nodes at 00:14:58Z
pods on ip-10-0-11-25.us-east-2.compute.internal: 14
pods on ip-10-0-11-151.us-east-2.compute.internal: 7
pods on ip-10-0-12-113.us-east-2.compute.internal: 19
scaled back to 2 nodes; every pod: 0 not Running (a drained node's pods reschedule — Day 2's two replicas)
NLB provisioned: a92b9136a46c946b78830761a7799346-7dbd7d457a7b01f1.elb.us-east-2.amazonaws.com
elbv2: a92b9136a46c946b78830761a7799346 network internet-facing provisioning
curl http://a92b9136a46c946b78830761a7799346-7dbd7d457a7b01f1.elb.us-east-2.amazonaws.com:8000/healthz -> HTTP 200 (your lab service, reachable by anyone — feel that)
NLB deleted: elbv2 count 0 at 00:23:23Z
log group /bhn-sim/containers	1	114723 (name, retention days, bytes)
streams (one per container): kube 
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
  None           None                         None
kube-system pods: aws coredns ebs-csi ebs-csi-controller eks-pod-identity kube 
no kube-apiserver / etcd / scheduler / controller-manager pods (compare: kubectl --context kind-bhn-sim get pods -n kube-system)
EKS says: status ACTIVE, k8s 1.33, platform eks.47, health issues: None
control-plane logs: /aws/eks/bhn-sim/cluster	21681629 (api, audit, authenticator — the only view you get)
Prometheus scrapes of scheduler/controller-manager/etcd/kube-proxy: disabled in k8s/kps-values-eks.yaml (they would be TargetDown forever)
kubectl whoami: arn:aws:sts::831926603642:assumed-role/AWSReservedSSO_AdministratorAccess_94b6a2c085503a21/barnesnest-kalan  groups system:authenticated
access entry: arn:aws:iam::831926603642:role/aws-reserved/sso.amazonaws.com/us-east-2/AWSReservedSSO_AdministratorAccess_94b6a2c085503a21
access entry: arn:aws:iam::831926603642:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS
access entry: arn:aws:iam::831926603642:role/lab-eks-node-group-239cf945ed431a806cba0c13e0
pod identity: kube-system/ebs-csi-controller-sa -> its own IAM role
pod identity: logging/fluent-bit -> its own IAM role
node ip-10-0-11-151.us-east-2.compute.internal: max-pods 110, allocatable cpu 1930m mem 3371528Ki
node ip-10-0-12-113.us-east-2.compute.internal: max-pods 110, allocatable cpu 1930m mem 3371536Ki
pods running: 30 (17 per t3.medium without prefix delegation — the platform alone would not have fit)
```
<!-- evidence:end -->
