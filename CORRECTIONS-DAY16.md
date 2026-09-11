# Day 16 — Corrections Log

Source: `day16eks.pdf` ("module and version numbers verified on 29 August 2026") · Built
10 September 2026 against the module's source on GitHub, not its README; the AWS side is
verified as the day runs.

---

## [BUG] B1 — Region, again

**Guide, Steps 1–2:** `ap-southeast-1` in `update-kubeconfig` and in the Fluent Bit output.
`us-east-2`, one variable (Day 15 B1): `AWS_REGION` in `lib.sh`, `var.region` in every root,
`__REGION__` rendered into the CloudWatch values by Terraform.

---

## [BUG] B2 — The PDF's cluster has no CNI: nodes never go Ready

**Guide, Step 1:** `eks.tf` declares a cluster and a node group and nothing else. Module
**v21 hard-codes `bootstrap_self_managed_addons = false`** (`main.tf`, checked) — EKS no
longer installs `vpc-cni`, `coredns` and `kube-proxy` by itself; you declare them in
`addons`. Apply the PDF's file and the node group's instances join, get no pod network,
and sit `NotReady` until the node group creation times out. **Substitute:** `addons` with
the three basics, `eks-pod-identity-agent`, and `aws-ebs-csi-driver`; `vpc-cni` and the
pod-identity agent flagged `before_compute = true` so they exist before a node joins.

---

## [BUG] B3 — "Attach CloudWatchAgentServerPolicy to the node role" does nothing for a pod

**Guide, Step 2.** Since v21 the managed node group's **IMDS hop limit defaults to 1**
(upgrade notes, checked): a pod cannot reach the instance metadata service, so it cannot
borrow the node role's credentials. Fluent Bit with the node-role policy attached would
log `no credentials` and ship nothing — silently, from the PDF's point of view, because
"confirm in CloudWatch" is the only check it offers. That default is *deliberate*: a
compromised pod should not inherit its node's powers. **Substitute:** **EKS Pod Identity**
— an IAM role per service account (`infra/aws/eks/pod-identity.tf`): `logging/fluent-bit`
→ `CloudWatchAgentServerPolicy`; `kube-system/ebs-csi-controller-sa` →
`AmazonEBSCSIDriverPolicy`, declared on the add-on. No node-role policies, no hop-limit
hack. This is the "IRSA or Pod Identity — recognise the vocabulary" from Step 4 item 5,
built instead of skimmed, because the day needed it.

---

## [BUG] B4 — `module.eks.name` is not an output

**Guide, Step 1:** `output "cluster_name" { value = module.eks.name }`. v21 renamed the
*inputs* (`cluster_name` → `name`, `cluster_version` → `kubernetes_version`, `cluster_addons`
→ `addons`, `cluster_endpoint_public_access` → `endpoint_public_access`) — the PDF has those
right — but the *output* is still `cluster_name` (`outputs.tf`, checked). `terraform
validate` refuses the file. The root outputs the name from its own local.

---

## [BUG] B5 — "Only provider changes" is not true on a managed control plane

**Guide, Step 2:** copy `infra/local`, change the providers, done. kube-prometheus-stack's
defaults scrape `kube-scheduler`, `kube-controller-manager`, `etcd` and `kube-proxy`. On EKS
the first three do not exist as targets (AWS runs them, out of reach) and kube-proxy binds
its metrics to localhost — four **permanently down targets** and their alerts
(`KubeSchedulerDown`, `KubeControllerManagerDown`, `etcd*`, `TargetDown`) on a healthy
cluster: Day 14's "kind false positives", reborn, honest this time. **Substitute:**
`k8s/kps-values-eks.yaml`, layered over `kps-values.yaml` — those four off, plus a
Prometheus request/limit for two small spot nodes. The PDF's own item 4 ("the control
plane is not yours") *is* this values file.

---

## [BUG] B6 — The Logs Insights query matches nothing

**Guide, Step 4 item 3:** `fields @timestamp, log | filter log like /activation failed/`.
Two faults in one line. With `Merge_Log On` + `Keep_Log Off` (the Day 3 fix that made
`app.*` searchable — the same filters ship to CloudWatch), there is **no `log` field**;
the JSON is merged as `app.*`. And the services never log the sentence "activation
failed"; they log `status=error reason=fraud_service_timeout`. **Substitute:**
`fields @timestamp, app.service, app.status, app.reason | filter app.status = "error"
| stats count() by app.service, app.reason` — the Day 3 Splunk search, in the other
pane. `165` and `166` run it through the CLI and print the result.

---

## [BUG] B7 — The incident-bot's volume needs a driver EKS does not ship

**Guide, Step 3:** "copy the manifests, change only the image references". Day 8's B3 gave
the incident-bot a PersistentVolumeClaim (kind's local-path provisioner made it free).
EKS has no in-tree EBS provisioner since 1.23; without the `aws-ebs-csi-driver` add-on the
PVC stays `Pending`, the pod never schedules, and the drill has no bot. **Substitute:** the
add-on (B2) with its Pod Identity (B3); the `gp2` StorageClass EKS ships then provisions a
1 GiB volume. Corollary worth a line in eks-notes: the volume lives in **one AZ**; a pod
with a volume can only reschedule into that AZ.

---

## [BUG] B8 — Two t3.mediums hold 34 pods; the platform is ~30, plus the system's

**Guide, troubleshooting:** "Pods Pending with Insufficient cpu: t3.medium ×2 is snug".
The tighter limit is not CPU: with the VPC CNI every pod gets a real VPC IP from an ENI,
and a t3.medium's 3 ENIs × 6 IPs = **17 pods per node**, six of which are daemonsets
(kube-proxy, aws-node, pod-identity agent, ebs-csi node, node-exporter, fluent-bit).
Eleven slots per node for coredns ×2, ebs-csi controller ×2, the operator, Prometheus,
Alertmanager, Grafana, kube-state-metrics, pushgateway, Tempo, otel, five services × their
replicas, settlement jobs. It does not fit, and the symptom is `Pending — Too many pods`
on a node that is half idle. **Substitute:** **prefix delegation** on the `vpc-cni` add-on
(`ENABLE_PREFIX_DELEGATION=true`) — /28 blocks per ENI instead of single IPs; managed node
groups then compute max-pods (110) themselves. `161` prints the number. Sixth difference
in `docs/eks-notes.md`.

---

## [BUG] B9 — `kubectl config use-context aws-lab`

**Guide, Step 1:** "consider `kubectl config use-context aws-lab`". Consider not. Every lab
script has pinned `--context` since Day 1 precisely so a global current-context can never
aim a `delete` at the wrong cluster; flipping the global default to the cloud cluster puts
every bare `kubectl` you type for the rest of the day on the metered cluster, and every
script you forget to prefix on… whichever one the default is. **Substitute:** `161` writes
the context and leaves the current-context untouched; `lib.sh` reads `KUBE_CONTEXT` (default
kind) and **refuses any value that is not kind or `aws-lab`**; the Day 16 scripts export it
themselves; `160 destroy` removes the context when the cluster goes. The PDF's own
troubleshooting row ("kubectl hits the wrong cluster") is the incident this prevents.

---

## [BUG] B10 — "Watch AWS provision an NLB" — it provisions a Classic Load Balancer

**Guide, Step 4 item 2:** change the Service type and "watch AWS provision an NLB". Without
the AWS Load Balancer Controller (not installed; not needed today), the in-tree cloud
controller's default for `type: LoadBalancer` is a **Classic** ELB. An NLB takes the
annotation `service.beta.kubernetes.io/aws-load-balancer-type: nlb` (plus `scheme:
internet-facing` to be explicit). `166` annotates, patches, waits for the hostname, curls
it from the internet, patches back, and **waits until `elbv2` counts zero** — because the
PDF's own troubleshooting says an orphaned load balancer is what hangs the VPC destroy,
and "confirm the NLB is deleted" by eye is Day 15 B8 again.

---

## [DESIGN] D1 — Three roots, three state keys

The PDF puts EKS in the env root with the VPC and ECR: one `destroy` for everything, and
therefore **no way to keep the network and registry up ($1/day) without the cluster
($4/day)**, or to re-create the cluster without re-creating the VPC. Days 17–19 warm-start
from "network up"; `infra/aws/eks` (`key = eks/terraform.tfstate`) finds the VPC and the
private subnets **by the tags Day 15 put on them** — the same lookup the load-balancer
controller does — instead of a copied ID or a remote-state read. `infra/aws/platform` has
its own key too, as the PDF says.

## [DESIGN] D2 — `k8s/aws/` is generated, and the diff is the proof

The PDF says "copy and change the image references". `163 --render` does it from `k8s/`
with the tag ECR holds (= what kind runs, Day 15 D2), drops kind's NodePort front doors
(no host to map to; traffic arrives by port-forward), and stamps a GENERATED header. The
files are committed so `diff -r k8s k8s/aws` is the *complete* difference between the two
clusters, and `168` checks it is image lines only. Editing `k8s/aws/` by hand is the
mistake the header warns about.

## [DESIGN] D3 — One variable runs every script against the cloud

`lib.sh` line 9 was `KUBE_CONTEXT="kind-bhn-sim"`. Now `${KUBE_CONTEXT:-kind-bhn-sim}`,
exported, and the Python tools already read the same variable. So `06`, `09`, `100`,
`120`, `90`, `inc.py`, `rem.py`, the copilot — unchanged — run against EKS with
`KUBE_CONTEXT=aws-lab`. That is the strongest form of the PDF's "running identically on a
cloud it has never seen": not a parallel set of cloud scripts, the same ones. Two small
concessions: `06` takes `GRAFANA_PORT` (kind keeps :3000), and `100` on EKS writes no
Splunk URL (it is unreachable from Ohio) and says so.

## [DESIGN] D4 — Charts from a local cache (Day 15 D4, done)

`infra/aws/platform/tf.sh` pulls each chart+version once into `charts/` (gitignored) and
the releases point at the `.tgz` — a plan needs GitHub zero times. Day 15's evening, when
eight fetches failed three runs in a row, is why. `infra/local` keeps the repository form
for now (changing `chart` on a live release is a Day 17 change with a plan to read).

## [DESIGN] D5 — Secrets cross clusters through a pipe

`secret/ai-keys` (the Anthropic key) is needed on EKS. `163` pipes `kubectl get secret -o
json` from kind through a metadata-stripping one-liner into `kubectl apply` on `aws-lab`:
no file, no shell history, no log. Same rule as Day 9.

## [NOTE] N1 — INC-0018

The PDF logs the EKS drill as INC-0017; that was Day 14's second fault. The EKS drill is
**INC-0018**, compared row by row with **INC-0009** (the same drill on kind, Day 10).

## [NOTE] N2 — "Same as always: the load generators from your Mac against port-forwards"

On kind the generators use NodePorts 30080/30443 mapped by Day 1's cluster config; on EKS
there is no host mapping. `164` runs both generators through *supervised* port-forwards
on **18000/18010** — different ports because 30080/30443 are still kind's while it runs,
and a generator pointed at 30080 would test kind while you looked at EKS dashboards.

## [NOTE] N3 — Timings

Control plane ~8 min, node group ~3, add-ons ~2 (create); platform ~5; services ~2;
NLB ~3 up / ~2 down; node scale ~3 each way; cluster destroy ~10. About 35 minutes of
waiting on AWS in a 3-hour day; `DAY16.md` says what to read during the long one.

## [NOTE] N4 — What the checkpoint cannot check

Whether the six lines in `docs/eks-notes.md` are *yours* — it counts words in the column.
Whether the hypothesis on EKS was honest about the missing source — that is Eval 7, and
the grade is yours to write.

---

## Verified as correct

The create-learn-destroy framing; nodes private + endpoint public; SPOT for a one-day
lab and the reason; two nodes; access entries replacing aws-auth; the S3 key per root;
"same collector, different backend" as the point of the collector layer; the five
differences as the day's syllabus (kept, plus one); the destroy order (platform, then
env); keep the bucket, the images, SSO, the budget; the troubleshooting rows for spot
reclaim and the wrong-context habit.
