#!/usr/bin/env bash
# Day 16, Step 4 — what is different up here. Six differences, each PROVEN with a command
# and written as evidence into docs/eks-notes.md; the one-line-in-your-words column is
# yours. The PDF lists five; the sixth (pod density is an IP problem) bit while building
# the cluster and belongs on the list.
#
#   ./scripts/166-eks-differences.sh            all six, in order (~12 min: two of them wait on AWS)
#   ./scripts/166-eks-differences.sh 3          one of them
#   ./scripts/166-eks-differences.sh --quick    skip the two that wait (scale, load balancer)
export KUBE_CONTEXT=aws-lab
source "$(dirname "$0")/lib.sh"
require_aws; require_cluster
cd "$LAB_ROOT" || exit 1
NOTES="$LAB_ROOT/docs/eks-notes.md"
EV="$CHECKPOINTS/day16-evidence.txt"; : > "$EV"
ev() { printf '%s\n' "$*" | tee -a "$EV" | sed 's/^/  /'; }
ONLY="${1:-all}"; QUICK=0; [[ "$ONLY" == --quick ]] && { QUICK=1; ONLY=all; }
want() { [[ "$ONLY" == all || "$ONLY" == "$1" ]]; }
NG=$(aws eks list-nodegroups --cluster-name "$EKS_CLUSTER" --query 'nodegroups[0]' --output text)

if want 1; then
step "1 · Nodes are cattle with bills"
ev "$(k get nodes -o custom-columns='NODE:.metadata.name,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,AZ:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY:.metadata.labels.eks\.amazonaws\.com/capacityType,AGE:.metadata.creationTimestamp' --no-headers | awk '{printf "node %s  %s  %s  %s  since %s\n",$1,$2,$3,$4,$5}')"
say "  kind's node was a container that cost nothing and never left. These are EC2 instances with an hourly"
say "  price, an AZ, and a capacity type (SPOT: AWS can reclaim them with two minutes' notice)."
if (( QUICK == 0 )); then
  read -rp "  Scale the node group to 3 and watch pods spread? (~3 min there, ~3 back) [Enter / n] " a
  if [[ "$a" != n ]]; then
    aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER" --nodegroup-name "$NG" --scaling-config desiredSize=3 --query 'update.status' --output text | sed 's/^/  update: /'
    for _ in $(seq 1 36); do (( $(k get nodes --no-headers | grep -c ' Ready') >= 3 )) && break; sleep 5; done
    ev "scaled to 3: $(k get nodes --no-headers | grep -c ' Ready') Ready nodes at $(date -u +%T)Z"
    sleep 20
    ev "$(k get pods -A -o wide --no-headers | awk '{n[$8]++} END {for (k in n) printf "pods on %s: %d\n", k, n[k]}')"
    say "  The third node fills only with NEW pods (daemonsets + whatever reschedules); Kubernetes does not"
    say "  rebalance running pods by itself — the descheduler is a separate tool. Scaling back:"
    aws eks update-nodegroup-config --cluster-name "$EKS_CLUSTER" --nodegroup-name "$NG" --scaling-config desiredSize=2 --query 'update.status' --output text | sed 's/^/  update: /'
    for _ in $(seq 1 48); do (( $(k get nodes --no-headers | wc -l) <= 2 )) && break; sleep 5; done
    ev "scaled back to $(k get nodes --no-headers | wc -l) nodes; every pod: $(k get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l) not Running (a drained node's pods reschedule — Day 2's two replicas)"
    say "  Terraform drift note: the module ignores desired_size after creation on purpose (autoscalers change it);"
    say "  160 plan stays clean. min/max are still code."
  fi
fi
fi

if want 2; then
step "2 · LoadBalancer Services now mean money (and exposure)"
say "  On kind, type: LoadBalancer sat <pending> forever. Here the cloud controller provisions a real NLB in the"
say "  PUBLIC subnets — found by Day 15's kubernetes.io/role/elb tag — with a public DNS name. ~\$0.0225/h + LCUs,"
say "  and your lab service is on the internet. Then it is removed, and the removal is verified."
if (( QUICK == 0 )); then
  read -rp "  Create it? (~3 min up, ~2 min down) [Enter / n] " a
  if [[ "$a" != n ]]; then
    k annotate svc activation -n "$PAYMENTS_NS" service.beta.kubernetes.io/aws-load-balancer-type=nlb --overwrite >/dev/null
    k annotate svc activation -n "$PAYMENTS_NS" service.beta.kubernetes.io/aws-load-balancer-scheme=internet-facing --overwrite >/dev/null
    k patch svc activation -n "$PAYMENTS_NS" -p '{"spec":{"type":"LoadBalancer"}}' >/dev/null
    H=""; for _ in $(seq 1 40); do H=$(k get svc activation -n "$PAYMENTS_NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true); [[ -n "$H" ]] && break; sleep 5; done
    [[ -n "$H" ]] && ev "NLB provisioned: $H" || warn "no hostname after 200 s — kubectl --context aws-lab describe svc activation -n payments | tail (subnet tags? see events)"
    ev "$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type,Scheme,State.Code]' --output text | awk '{printf "elbv2: %s %s %s %s\n",$1,$2,$3,$4}')"
    if [[ -n "$H" ]]; then
      say "  Waiting for DNS + target health (up to 3 min), then one request from the public internet:"
      CODE=000; for _ in $(seq 1 36); do CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$H:8000/healthz" 2>/dev/null || echo 000); [[ "$CODE" == 200 ]] && break; sleep 5; done
      ev "curl http://$H:8000/healthz -> HTTP $CODE $( [[ "$CODE" == 200 ]] && echo '(your lab service, reachable by anyone — feel that)' || echo '(not yet; NLB target registration can take 3-4 min — not worth waiting for)')"
    fi
    say "  Removing: type back to ClusterIP — the controller deletes the NLB. The wait matters: an NLB left behind"
    say "  is the classic orphan that bills AND blocks the VPC destroy."
    k patch svc activation -n "$PAYMENTS_NS" -p '{"spec":{"type":"ClusterIP"}}' >/dev/null
    k annotate svc activation -n "$PAYMENTS_NS" service.beta.kubernetes.io/aws-load-balancer-type- service.beta.kubernetes.io/aws-load-balancer-scheme- >/dev/null 2>&1 || true
    for _ in $(seq 1 36); do (( $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text) == 0 )) && break; sleep 5; done
    N=$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)
    (( N == 0 )) && ev "NLB deleted: elbv2 count 0 at $(date -u +%T)Z" || { ev "elbv2 count still $N after 3 min"; warn "check again before teardown: 160 status"; }
  fi
fi
fi

if want 3; then
step "3 · CloudWatch is the second pane of glass"
G=$(aws logs describe-log-groups --log-group-name-prefix /bhn-sim/containers --query 'logGroups[0].[logGroupName,retentionInDays,storedBytes]' --output text 2>/dev/null || true)
[[ -n "$G" && "$G" != None ]] && ev "log group $G (name, retention days, bytes)" || warn "no /bhn-sim/containers group — Fluent Bit is not shipping (163's last check)"
S=$(aws logs describe-log-streams --log-group-name /bhn-sim/containers --query 'logStreams[].logStreamName' --output text 2>/dev/null | tr '\t' '\n' | sed 's/^payments\.//' | cut -d. -f1 | sort -u | tr '\n' ' ')
ev "streams (one per container): $S"
say "  Logs Insights — the query that works (app.* fields from Merge_Log; the PDF's \`filter log like\` matches nothing):"
Q=$(aws logs start-query --log-group-name /bhn-sim/containers --start-time "$(( $(date +%s) - 1800 ))" --end-time "$(date +%s)" \
     --query-string 'fields @timestamp, app.service, app.status, app.reason | filter app.status = "error" | stats count() by app.service, app.reason' --query queryId --output text 2>/dev/null || true)
if [[ -n "$Q" ]]; then sleep 6; aws logs get-query-results --query-id "$Q" --query 'results[].[ [0].value, [1].value, [2].value ]' --output text 2>/dev/null | awk '{printf "  %-14s %-28s %s\n",$1,$2,$3}' | tee -a "$EV"; fi
say "  Where it overlaps Splunk/Grafana: search, counts by field, a dashboard widget. Where it does not:"
say "  no PromQL, no SLO burn rate, no alert routing into the bot — and the bot has no CloudWatch collector"
say "  yet (its logs source says 'not configured' on EKS). Which question goes to which system is the skill."
fi

if want 4; then
step "4 · The control plane is not yours"
ev "kube-system pods: $(k get pods -n kube-system --no-headers | awk '{print $1}' | sed -E 's/-[a-z0-9]+(-[a-z0-9]+)?$//' | sort -u | tr '\n' ' ')"
ev "no kube-apiserver / etcd / scheduler / controller-manager pods (compare: kubectl --context kind-bhn-sim get pods -n kube-system)"
ev "$(aws eks describe-cluster --name "$EKS_CLUSTER" --query 'cluster.[status,version,platformVersion,health.issues]' --output text | awk '{printf "EKS says: status %s, k8s %s, platform %s, health issues: %s\n",$1,$2,$3,($4==""?"none":$4)}')"
ev "control-plane logs: $(aws logs describe-log-groups --log-group-name-prefix "/aws/eks/$EKS_CLUSTER/cluster" --query 'logGroups[0].[logGroupName,storedBytes]' --output text 2>/dev/null) (api, audit, authenticator — the only view you get)"
ev "Prometheus scrapes of scheduler/controller-manager/etcd/kube-proxy: disabled in k8s/kps-values-eks.yaml (they would be TargetDown forever)"
say "  When the API is slow at work the runbook says 'check the EKS console / AWS Health', not 'ssh to the master'."
fi

if want 5; then
step "5 · IAM is the new RBAC boundary"
ev "$(kubectl --context aws-lab auth whoami -o json 2>/dev/null | python3 -c 'import json,sys; u=json.load(sys.stdin)["status"]["userInfo"]; print("kubectl whoami: %s  groups %s" % (u.get("username"), ",".join(u.get("groups",[]))))' 2>/dev/null || echo "auth whoami unavailable")"
ev "$(aws eks list-access-entries --cluster-name "$EKS_CLUSTER" --query 'accessEntries' --output text | tr '\t' '\n' | sed 's/^/access entry: /')"
ev "$(aws eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER" --query 'associations[].[namespace,serviceAccount]' --output text | awk '{printf "pod identity: %s/%s -> its own IAM role\n",$1,$2}')"
say "  Your SSO role is cluster-admin through an ACCESS ENTRY (not the aws-auth ConfigMap). Two pods have AWS"
say "  permissions — the EBS CSI driver and Fluent Bit — through POD IDENTITY: an IAM role per service account,"
say "  least privilege with a name on it. Nothing borrows the node's role (the IMDS hop limit is 1 since module v21)."
fi

if want 6; then
step "6 · Pod density is an IP-address problem (the one the PDF does not list)"
ev "$(k get nodes -o custom-columns='NODE:.metadata.name,MAX-PODS:.status.allocatable.pods,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory' --no-headers | awk '{printf "node %s: max-pods %s, allocatable cpu %s mem %s\n",$1,$2,$3,$4}')"
ev "pods running: $(k get pods -A --no-headers | grep -c Running) (17 per t3.medium without prefix delegation — the platform alone would not have fit)"
say "  On kind, pods got IPs from a private overlay. On EKS with the VPC CNI every pod gets a REAL VPC IP from an"
say "  ENI, and a t3.medium has 3 ENIs x 6 IPs = 17 pods. Prefix delegation (vpc-cni add-on config) hands out /28"
say "  blocks instead; 'Pending — Too many pods' on a half-idle node is one of the most common EKS tickets."
fi

step "docs/eks-notes.md"
python3 - "$NOTES" "$EV" <<'PY'
import sys, re, datetime
notes, ev = sys.argv[1], sys.argv[2]
s = open(notes).read()
block = "<!-- evidence:start -->\n## Evidence (generated by scripts/166-eks-differences.sh, %s)\n\n```\n%s```\n<!-- evidence:end -->" % (datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%MZ"), open(ev).read())
if "<!-- evidence:start -->" in s:
    s = re.sub(r"<!-- evidence:start -->.*?<!-- evidence:end -->", block, s, flags=re.S)
else:
    s = s.rstrip("\n") + "\n\n" + block + "\n"
open(notes, "w").write(s)
PY
ok "evidence written into docs/eks-notes.md — now the one line in your words for each, in the table at the top"
ok "Next: the teardown when you are done looking — ./scripts/167-eks-teardown.sh"
