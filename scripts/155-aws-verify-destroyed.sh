#!/usr/bin/env bash
# "Verify with your eyes" — with a script, because the stray EIP is the single most common
# leftover (the PDF's own troubleshooting note) and eyes are bad at empty lists. Exit 1 if
# anything that bills is still there. Run after every destroy, and every morning of week 3.
source "$(dirname "$0")/lib.sh"
require_aws
step "Anything left in $AWS_REGION that bills?"
LEFT=0
chk() {  # label count details
  if [[ "$2" == 0 ]]; then ok "$1: none"; else warn "$1: $2  $3"; LEFT=$((LEFT+1)); fi
}
I=$(aws ec2 describe-instances --filters 'Name=instance-state-name,Values=running,pending,stopping,stopped' --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text 2>/dev/null); chk "EC2 instances" "$(echo -n "$I" | grep -c . || true)" "$(echo "$I" | tr '\n' ';')"
N=$(aws ec2 describe-nat-gateways --filter 'Name=state,Values=available,pending,deleting' --query 'NatGateways[].[NatGatewayId,State]' --output text 2>/dev/null); chk "NAT gateways" "$(echo -n "$N" | grep -c . || true)" "$(echo "$N" | tr '\n' ';')"
E=$(aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AssociationId||`unattached`]' --output text 2>/dev/null); chk "Elastic IPs" "$(echo -n "$E" | grep -c . || true)" "$(echo "$E" | tr '\n' ';') — released EIPs stop billing; unattached ones do not"
L=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].[LoadBalancerName,Type]' --output text 2>/dev/null); chk "Load balancers" "$(echo -n "$L" | grep -c . || true)" "$(echo "$L" | tr '\n' ';')"
K=$(aws eks list-clusters --query 'clusters' --output text 2>/dev/null); chk "EKS clusters" "$(echo -n "$K" | wc -w)" "$K"
V=$(aws ec2 describe-vpcs --filters 'Name=tag:project,Values=bhn-sim' --query 'Vpcs[].VpcId' --output text 2>/dev/null); chk "lab VPCs" "$(echo -n "$V" | wc -w)" "$V (free, but a sign destroy did not finish)"
EN=$(aws ec2 describe-network-interfaces --filters 'Name=status,Values=available' --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0); chk "orphan ENIs (available)" "$EN" "the thing that makes a VPC destroy hang"
VOL=$(aws ec2 describe-volumes --filters 'Name=status,Values=available' --query 'length(Volumes)' --output text 2>/dev/null || echo 0); chk "unattached EBS volumes" "$VOL" "bill per GB-month"
say "  kept on purpose: S3 state bucket, ECR repositories (when env is up), SSO, the budget"

# Day 15 (B9): the lab lives in one region; the bill does not. A stopped t2.xlarge, three
# unattached EIPs and a KMS key in us-east-1 — from a first attempt at the lab — cost
# $0.51/day for ten days while this script said "nothing billing" about us-east-2.
# Every enabled region, the five things that bill while idle; ~1 s per region.
step "Every other region — anything at all?"
OTHER=0
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null); do
  [[ "$r" == "$AWS_REGION" ]] && continue
  a=$(aws ec2 describe-addresses --region "$r" --query 'length(Addresses)' --output text 2>/dev/null || echo ?)
  i=$(aws ec2 describe-instances --region "$r" --query 'length(Reservations[].Instances[?State.Name!=`terminated`][])' --output text 2>/dev/null || echo ?)
  v=$(aws ec2 describe-volumes --region "$r" --query 'length(Volumes)' --output text 2>/dev/null || echo ?)
  n=$(aws ec2 describe-nat-gateways --region "$r" --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text 2>/dev/null || echo ?)
  l=$(aws elbv2 describe-load-balancers --region "$r" --query 'length(LoadBalancers)' --output text 2>/dev/null || echo ?)
  # customer-managed keys that are NOT already scheduled for deletion (those stop billing at deletion; a
  # cancelled schedule would bring one back — hence still checked every morning)
  k=0
  for kid in $(aws kms list-aliases --region "$r" --query 'Aliases[?!starts_with(AliasName,`alias/aws/`)].TargetKeyId' --output text 2>/dev/null); do
    st=$(aws kms describe-key --region "$r" --key-id "$kid" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo ?)
    [[ "$st" == PendingDeletion ]] || k=$((k+1))
  done
  if [[ "$a$i$v$n$l$k" != 000000 ]]; then
    warn "$r: eips=$a instances=$i volumes=$v nat=$n load-balancers=$l kms-keys=$k"; OTHER=$((OTHER+1))
  fi
done
(( OTHER == 0 )) && ok "no EC2, EIP, volume, NAT, load balancer or live customer KMS key in any other region" || LEFT=$((LEFT+OTHER))

if (( LEFT == 0 )); then ok "nothing billing by the hour"; else warn "$LEFT kind(s) of leftover — delete in the console or re-run destroy"; exit 1; fi
