#!/usr/bin/env python3
"""Fills the six 'In my words' cells and adds two bullets to docs/eks-notes.md IN PLACE,
leaving the evidence block 166 generated untouched. Idempotent."""
import re, sys, pathlib
p = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs/eks-notes.md"); s = p.read_text()
words = {
 1: "Every node is a bill and a rumour: mine got a spot rebalance warning 90 s after birth, AWS launched a replacement, drained the old one, and I never dropped below two — scale up fills the new node with daemonsets only, scale down drains one and the two-replica services just move.",
 2: "`type: LoadBalancer` is a purchase and a door: nine minutes from patch to a public NLB answering `curl` from the internet to deleted-and-verified — always check `elbv2` is back to zero, because an orphaned one bills and blocks the VPC destroy.",
 3: "Fluent Bit shipped the same JSON to CloudWatch with no credential in the config (Pod Identity); Logs Insights answered the Day 3 question in one query (`fraud_service_timeout 894`) — but the bot can't read it yet, so ask CloudWatch for 'which reason', Grafana for 'how bad', and know which one you're in.",
 4: "There's no `kube-apiserver` pod to describe and no scheduler to scrape — AWS runs them, the chart's scrapes of them are switched off, and 'the API is slow' becomes a look at EKS status and `/aws/eks/bhn-sim/cluster`, not an ssh.",
 5: "My SSO role is admin through an access entry, not `aws-auth`; the two pods that talk to AWS (EBS CSI, Fluent Bit) each have their own IAM role via Pod Identity, and nothing borrows the node's — so 'AccessDenied in a pod' is an IAM question first.",
 6: "Pods eat VPC IPs: a t3.medium holds 17 without prefix delegation and I was going to run 30 — with it, 110 per node; 'Pending — Too many pods' on a node with spare CPU is an IP problem, not a capacity one.",
}
n = 0
for k, w in words.items():
    m = re.search(r'^(\| %d \| .*? \|) (\|.*)$' % k, s, re.M)   # empty middle cell only
    if m and w not in s:
        s = s[:m.start()] + m.group(1) + " " + w + " " + m.group(2) + s[m.end():]; n += 1
bul = '''- **No default StorageClass** (EKS ≥ 1.30): a PVC with no class waits forever. The
  platform root now ships a default gp3 class (`storage.tf`); the incident-bot's claim
  bound only after it existed (B12).
- **The API service proxy is a network path.** `kubectl get --raw …/proxy` — every lab
  tool's route to Prometheus, Alertmanager, the bot — needs the control plane allowed
  into the nodes on those ports. One security-group rule (`eks.tf`, B13); on kind, nothing.
- **Two clusters, one kubeconfig.**'''
if "No default StorageClass" not in s:
    s = s.replace("- **Two clusters, one kubeconfig.**", bul, 1)
p.write_text(s)
print("eks-notes: %d rows filled; evidence block %s" % (n, "kept" if "evidence:start" in s else "absent"))
