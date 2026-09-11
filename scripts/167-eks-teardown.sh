#!/usr/bin/env bash
# Day 16, Step 5 — destroy, in the order that does not hang, and VERIFY the destroy with a
# script (Day 15 B8/B9: eyes are bad at empty lists, and the bill is not one region).
#
#   1. anything a Service created outside Terraform: LoadBalancers back to ClusterIP
#   2. the platform root  (helm releases, namespaces -> the services, the PVC -> its EBS volume)
#   3. the eks root       (node group, cluster, add-ons, pod-identity roles, KMS key, log group)
#   4. the CloudWatch log group Fluent Bit auto-created (outside Terraform on purpose)
#   5. 155 — every region
#   6. optionally the env root too (--all): VPC, NAT, ECR + images. Days 17–19 warm-start
#      from env-up in ~15 min (160 + 162 + 163), from nothing in ~25.
#
#   ./scripts/167-eks-teardown.sh          keep the network + registry (~$1.10/day, the NAT)
#   ./scripts/167-eks-teardown.sh --all    everything: nothing bills by the hour afterwards
export KUBE_CONTEXT=aws-lab
source "$(dirname "$0")/lib.sh"
require_aws
cd "$LAB_ROOT" || exit 1
T0=$(date +%s)

step "1 · Services of type LoadBalancer (an NLB left behind bills and blocks the VPC destroy)"
if kubectl --context aws-lab get svc -A >/dev/null 2>&1; then
  LBS=$(kubectl --context aws-lab get svc -A --no-headers 2>/dev/null | awk '$5=="LoadBalancer"{print $1"/"$2}' || true)
  if [[ -n "$LBS" ]]; then
    for s in $LBS; do kubectl --context aws-lab patch svc "${s#*/}" -n "${s%/*}" -p '{"spec":{"type":"ClusterIP"}}' >/dev/null && warn "reverted $s to ClusterIP"; done
    for _ in $(seq 1 36); do (( $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text) == 0 )) && break; sleep 5; done
  fi
  ok "no LoadBalancer Services; elbv2 count $(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text)"
else
  warn "cluster not answering on aws-lab — skipping (already destroyed?)"
fi

step "2 · Platform root"
if [[ -d "$AWS_PLATFORM/.terraform" ]] && kubectl --context aws-lab get ns >/dev/null 2>&1; then
  "$LAB_ROOT/scripts/162-eks-platform.sh" destroy
else
  say "  nothing to destroy (no state init, or the cluster is gone — the cluster destroy takes the namespaces with it)"
fi

step "3 · EKS root"
"$LAB_ROOT/scripts/160-eks.sh" destroy

step "4 · CloudWatch: the log group Fluent Bit created (auto_create_group — not Terraform's)"
aws logs delete-log-group --log-group-name /bhn-sim/containers 2>/dev/null && ok "deleted /bhn-sim/containers" || say "  /bhn-sim/containers already gone"

if [[ "${1:-}" == --all ]]; then
  step "5 · Env root (VPC, NAT, ECR + images)"
  "$LAB_ROOT/scripts/152-aws-vpc.sh" destroy      # ends with 155 itself
else
  step "5 · Every region"
  "$LAB_ROOT/scripts/155-aws-verify-destroyed.sh" || warn "the NAT + its EIP are the env root, kept on purpose (--all removes them); anything ELSE listed is a leftover"
fi

date -u +%FT%TZ > "$CHECKPOINTS/day16-torn-down.txt"
ok "teardown finished in $(( ($(date +%s) - T0) / 60 )) min — tomorrow: ./scripts/154-aws-cost.sh --row 16"
