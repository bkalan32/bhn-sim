#!/usr/bin/env bash
# Day 16, Step 1 — the managed cluster, by module. Its own root and state key
# (infra/aws/eks) so the $4/day compute layer comes and goes without touching the $1/day
# network + registry layer (CORRECTIONS-DAY16 D1).
#
#   ./scripts/160-eks.sh plan      ~50 resources, summarised by kind — read the categories
#   ./scripts/160-eks.sh apply     10–15 minutes (the control plane is the slow part); then 161
#   ./scripts/160-eks.sh status    cluster, node group, nodes, add-ons, what it costs per hour
#   ./scripts/160-eks.sh destroy   the compute layer only; 167 runs this after the platform destroy
source "$(dirname "$0")/lib.sh"
require_aws
cd "$LAB_ROOT" || exit 1
[[ -f "$AWS_ENV/backend.hcl" ]] || die "no infra/aws/env/backend.hcl — ./scripts/151-aws-state.sh first"
[[ -f "$AWS_EKS/backend.hcl" ]] || { sed 's/151-aws-state.sh/160-eks.sh (copied from env)/' "$AWS_ENV/backend.hcl" > "$AWS_EKS/backend.hcl"; ok "infra/aws/eks/backend.hcl (same bucket, key eks/terraform.tfstate)"; }

summarise_plan() {
  python3 - "$1" <<'PY'
import re, sys, collections
c = collections.Counter()
for m in re.finditer(r'# (\S+) will be (created|destroyed|updated|replaced)', open(sys.argv[1]).read()):
    addr, act = m.groups()
    typ = next((p for p in addr.split('.') if p.startswith('aws_')), addr)
    c[(act, typ.split('[')[0])] += 1
for (act, typ), n in sorted(c.items()):
    print("  %-9s %-44s x%d" % (act, typ, n))
PY
}
env_up() { aws ec2 describe-vpcs --filters "Name=tag:Name,Values=bhn-sim" "Name=tag:project,Values=bhn-sim" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0; }

case "${1:-}" in
  plan)
    [[ "$(env_up)" == 1 ]] || die "no lab VPC found — the env root is not applied: ./scripts/152-aws-vpc.sh plan && apply"
    step "terraform plan — infra/aws/eks (cluster, node group, IAM, security groups, OIDC, add-ons, pod identity)"
    tf_aws "$AWS_EKS" plan -input=false -no-color -var "region=$AWS_REGION" -out=eks.tfplan > "$AWS_EKS/plan.txt" 2>&1 || { tail -20 "$AWS_EKS/plan.txt"; die "plan failed"; }
    summarise_plan "$AWS_EKS/plan.txt"
    grep -E '^Plan:' "$AWS_EKS/plan.txt" | sed 's/^/  /'
    say ""
    say "  Read for: ONE aws_eks_cluster, ONE aws_eks_node_group (SPOT, t3.medium/t3a.medium, 2..3),"
    say "  FIVE aws_eks_addon (coredns, kube-proxy, vpc-cni, pod-identity-agent, ebs-csi), TWO"
    say "  aws_iam_role for pods (ebs-csi, fluent-bit) + the cluster and node roles, an access entry"
    say "  for your SSO role, a KMS key (secrets encryption), a CloudWatch log group (1-day retention)."
    ok "Next: $0 apply   (~\$0.10/h control plane + 2 spot t3.medium ≈ \$0.03/h + NAT ≈ \$4/day all in)"
    ;;
  apply)
    [[ -f "$AWS_EKS/eks.tfplan" ]] || die "no saved plan — $0 plan first, and read it"
    step "terraform apply — infra/aws/eks (10–15 min: the control plane ~8, the node group ~3, add-ons ~2)"
    say "  Read DAY16.md 'While it builds' meanwhile."
    T0=$(date +%s)
    tf_aws "$AWS_EKS" apply -input=false -no-color eks.tfplan > "$AWS_EKS/apply.txt" 2>&1 || { grep -E '^\s*(│ )?Error' -A4 "$AWS_EKS/apply.txt" | head -20; die "apply failed — infra/aws/eks/apply.txt (a partial cluster is normal: fix, plan, apply again — it converges)"; }
    rm -f "$AWS_EKS/eks.tfplan"
    grep -E '^Apply complete' "$AWS_EKS/apply.txt" | sed 's/^/  /'
    ok "applied in $(( ($(date +%s) - T0) / 60 )) min"
    date -u +%FT%TZ > "$CHECKPOINTS/day16-eks-applied.txt"
    "$LAB_ROOT/scripts/161-eks-kubeconfig.sh"
    ;;
  status)
    step "EKS in $AWS_REGION"
    ST=$(aws eks describe-cluster --name "$EKS_CLUSTER" --query 'cluster.[status,version,endpoint,health.issues]' --output json 2>/dev/null || echo '[]')
    if [[ "$ST" == "[]" ]]; then say "  cluster $EKS_CLUSTER: not found (destroyed, or never applied)"; else
      python3 -c 'import json,sys; s,v,e,h=json.load(sys.stdin); print("  cluster %s: %s  k8s %s  health issues: %s" % (sys.argv[1], s, v, h or "none"))' "$EKS_CLUSTER" <<<"$ST"
      aws eks list-nodegroups --cluster-name "$EKS_CLUSTER" --query 'nodegroups' --output text 2>/dev/null | tr '\t' '\n' | while read -r ng; do
        [[ -n "$ng" ]] || continue
        aws eks describe-nodegroup --cluster-name "$EKS_CLUSTER" --nodegroup-name "$ng" --query 'nodegroup.[status,capacityType,join(`,`,instanceTypes),scalingConfig.desiredSize,scalingConfig.minSize,scalingConfig.maxSize]' --output text | awk -v n="$ng" '{printf "  node group %s: %s %s %s desired=%s (min %s, max %s)\n", n, $1, $2, $3, $4, $5, $6}'
      done
      aws eks list-addons --cluster-name "$EKS_CLUSTER" --query 'addons' --output text 2>/dev/null | tr '\t' '\n' | while read -r a; do
        [[ -n "$a" ]] || continue
        aws eks describe-addon --cluster-name "$EKS_CLUSTER" --addon-name "$a" --query 'addon.[status,addonVersion]' --output text | awk -v a="$a" '{printf "  add-on %-24s %s %s\n", a, $1, $2}'
      done
      if kubectl config get-contexts -o name 2>/dev/null | grep -qx aws-lab; then
        kubectl --context aws-lab get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,AZ:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY:.metadata.labels.eks\.amazonaws\.com/capacityType,PODS:.status.allocatable.pods' 2>/dev/null | sed 's/^/  /' || say "  (context aws-lab present but the API did not answer — aws sso login?)"
      fi
    fi
    I=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" --query 'length(Reservations[].Instances[])' --output text); say "  EC2 instances running: $I   (spot t3.medium ≈ \$0.013/h each; control plane \$0.10/h; NAT \$0.045/h)"
    L=$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); C=$(aws elb describe-load-balancers --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null || echo 0)
    say "  load balancers: $L (NLB/ALB) + $C (classic)   — anything above 0 is a Service you forgot to revert (166 step 2)"
    ;;
  destroy)
    step "terraform destroy — infra/aws/eks (cluster, nodes, add-ons, pod-identity roles, KMS key, log group)"
    say "  Keeps: the VPC/NAT/ECR (env root), the state bucket, SSO, the budget. Re-create is ~15 minutes (160 plan/apply)."
    LB=$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); CLB=$(aws elb describe-load-balancers --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null || echo 0)
    (( LB + CLB == 0 )) || die "$((LB+CLB)) load balancer(s) still exist — a Service of type LoadBalancer was not reverted; the VPC destroy would hang on it. kubectl --context aws-lab get svc -A | grep LoadBalancer"
    if kubectl --context aws-lab get ns payments >/dev/null 2>&1 && kubectl --context aws-lab get pvc -A --no-headers 2>/dev/null | grep -c . >/dev/null; then
      warn "PersistentVolumeClaims still exist (the incident-bot's) — the platform root should be destroyed first (./scripts/167-eks-teardown.sh does the order); an EBS volume can outlive the cluster"
      read -rp "  Continue anyway? [type yes] " a; [[ "$a" == yes ]] || die "not destroying"
    else
      read -rp "  Destroy the cluster? [type yes] " a; [[ "$a" == yes ]] || die "not destroying"
    fi
    T0=$(date +%s)
    tf_aws "$AWS_EKS" destroy -input=false -auto-approve -no-color -var "region=$AWS_REGION" > "$AWS_EKS/apply.txt" 2>&1 || { grep -E '^\s*(│ )?Error' -A4 "$AWS_EKS/apply.txt" | head -20; die "destroy failed — infra/aws/eks/apply.txt; usually an orphan ENI/volume: ./scripts/155-aws-verify-destroyed.sh names it"; }
    grep -E '^Destroy complete' "$AWS_EKS/apply.txt" | sed 's/^/  /'
    ok "destroyed in $(( ($(date +%s) - T0) / 60 )) min"
    date -u +%FT%TZ > "$CHECKPOINTS/day16-eks-destroyed.txt"
    ARN="arn:aws:eks:${AWS_REGION}:$(aws_account):cluster/${EKS_CLUSTER}"
    kubectl config delete-context aws-lab >/dev/null 2>&1 && ok "kubeconfig: context aws-lab removed (a context to a dead cluster is a trap)" || true
    kubectl config delete-cluster "$ARN" >/dev/null 2>&1 || true; kubectl config delete-user "$ARN" >/dev/null 2>&1 || true
    ;;
  *) die "usage: $0 plan|apply|status|destroy" ;;
esac
