#!/usr/bin/env bash
# The whole AWS account, every enabled region — READ-ONLY. 155 answers "does the lab's region bill
# by the hour?"; this answers "is there anything, anywhere, that the lab (or anything else) left?"
#
#   ./scripts/156-aws-account-audit.sh
#
# Sections: 1 what it actually costs (Cost Explorer), 2 global things (IAM, S3, DNS, CDN, budgets),
# 3 every region (~25 checks each, regions in parallel), 4 anything still tagged project=bhn-sim.
# "bills" = costs money while idle; "note" = free but left over. Exit 1 if anything bills.
# The account id is masked in the output (the repo is public; so are screenshots of this).
# Cost Explorer charges $0.01 per request; this makes two.
source "$(dirname "$0")/lib.sh"
require_aws
ACCT=$(aws_account)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mask() { sed -E "s/$ACCT/<acct>/g"; }
BILL=0; NOTE=0
bills() { warn "bills  $*" | mask; BILL=$((BILL+1)); }
note()  { say "  note  $*" | mask; NOTE=$((NOTE+1)); }
q() { "$@" 2>/dev/null || true; }             # a check that cannot run prints nothing, not an error

step "1 · What the account actually costs (Cost Explorer)"
START=$(date -u +%Y-%m-01); END=$(date -u -d tomorrow +%F)
[[ "$START" == "$(date -u +%F)" ]] && START=$(date -u -d "last month" +%Y-%m-01)
q aws ce get-cost-and-usage --region us-east-1 --time-period "Start=$START,End=$END" --granularity MONTHLY \
  --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE --output json > "$T/ce-month.json"
q aws ce get-cost-and-usage --region us-east-1 --time-period "Start=$(date -u -d '7 days ago' +%F),End=$END" \
  --granularity DAILY --metrics UnblendedCost --output json > "$T/ce-days.json"
python3 - "$T" "$START" <<'PY'
import json, sys, pathlib
t = pathlib.Path(sys.argv[1])
try:
    m = json.loads((t / "ce-month.json").read_text())
    rows = [(g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])) for r in m["ResultsByTime"] for g in r["Groups"]]
    rows = sorted([r for r in rows if r[1] >= 0.005], key=lambda r: -r[1])
    print(f"  since {sys.argv[2]}: ${sum(c for _, c in rows):.2f}")
    for s, c in rows: print(f"     ${c:7.2f}  {s}")
    d = json.loads((t / "ce-days.json").read_text())
    print("  last 7 days: " + "  ".join(f"{r['TimePeriod']['Start'][5:]} ${float(r['Total']['UnblendedCost']['Amount']):.2f}" for r in d["ResultsByTime"]))
    print("  (Cost Explorer lags ~24 h; the last day or two fill in later. What matters: it trends to ~0.)")
except Exception as e:
    print(f"  Cost Explorer not readable ({type(e).__name__}) — check Billing > Cost Explorer in the console")
PY

step "2 · Global: identity, storage, DNS, CDN, budgets"
U=$(q aws iam list-users --query 'Users[].UserName' --output text)
[[ -n "$U" ]] && note "IAM users: $U — SSO is the way in; a user is a standing credential" || ok "IAM users: none (SSO only)"
for u in $U; do
  K=$(q aws iam list-access-keys --user-name "$u" --query 'AccessKeyMetadata[?Status==`Active`].AccessKeyId' --output text)
  [[ -n "$K" ]] && bills "active access key(s) for $u: $(echo "$K" | wc -w) — not money, risk: delete unless needed"
done
R=$(q aws iam list-roles --query 'Roles[?!starts_with(Path,`/aws-service-role/`) && !starts_with(Path,`/aws-reserved/`)].RoleName' --output text)
[[ -n "$R" ]] && note "IAM roles you (or Terraform) created: $(echo "$R" | tr '\t' ' ')" || ok "no custom IAM roles"
O=$(q aws iam list-open-id-connect-providers --query 'length(OpenIDConnectProviderList)' --output text)
[[ "${O:-0}" != 0 ]] && note "OIDC providers: $O (an EKS leftover if nothing uses it)" || ok "no OIDC providers"
P=$(q aws iam list-policies --scope Local --query 'Policies[].PolicyName' --output text)
[[ -n "$P" ]] && note "customer-managed IAM policies: $(echo "$P" | tr '\t' ' ')" || ok "no customer-managed IAM policies"
for b in $(q aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  N=$(q aws s3api list-object-versions --bucket "$b" --max-items 1000 --query 'length(Versions || `[]`)' --output text | head -1)
  note "S3 bucket $b — ${N:-?} object version(s) (the Terraform state bucket is kept on purpose: cents/month)"
done
Z=$(q aws route53 list-hosted-zones --query 'HostedZones[].Name' --output text)
[[ -n "$Z" ]] && bills "Route 53 hosted zones (\$0.50/month each): $Z" || ok "no Route 53 hosted zones"
C=$(q aws cloudfront list-distributions --query 'length(DistributionList.Items || `[]`)' --output text)
[[ "${C:-0}" != 0 && "$C" != None ]] && bills "CloudFront distributions: $C" || ok "no CloudFront distributions"
BU=$(q aws budgets describe-budgets --account-id "$ACCT" --query 'Budgets[].[BudgetName,BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount]' --output text)
[[ -n "$BU" ]] && ok "budget(s) — keep: $(echo "$BU" | awk '{printf "%s limit $%.0f, spent $%.2f; ", $1, $2, $3}')" || warn "no budget — the one guardrail worth keeping"

step "3 · Every enabled region (in parallel, ~30-60 s)"
region() {  # r -> lines "bills|note <region> <what> <n> <names>"
  set +e +o pipefail                           # a background job: one service missing in a region must not end the rest
  local r=$1 n x
  c() { local kind=$1 what=$2; shift 2; n=$("$@" --region "$r" --output text 2>/dev/null | head -1); [[ -n "$n" && "$n" != 0 && "$n" != None ]] && echo "$kind $r $what $n"; }
  c bills "EC2 instances (not terminated; stopped ones still bill their disks)" aws ec2 describe-instances --query 'length(Reservations[].Instances[?State.Name!=`terminated`][])'
  c bills "Elastic IPs" aws ec2 describe-addresses --query 'length(Addresses)'
  c bills "EBS volumes" aws ec2 describe-volumes --query 'length(Volumes)'
  c bills "EBS snapshots (yours)" aws ec2 describe-snapshots --owner-ids self --query 'length(Snapshots)'
  c bills "AMIs (yours)" aws ec2 describe-images --owners self --query 'length(Images)'
  c bills "NAT gateways" aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'length(NatGateways)'
  c bills "load balancers (ALB/NLB)" aws elbv2 describe-load-balancers --query 'length(LoadBalancers)'
  c bills "classic load balancers" aws elb describe-load-balancers --query 'length(LoadBalancerDescriptions)'
  c bills "VPC endpoints (interface ones bill hourly)" aws ec2 describe-vpc-endpoints --query 'length(VpcEndpoints[?VpcEndpointType==`Interface`])'
  c bills "EKS clusters" aws eks list-clusters --query 'length(clusters)'
  c bills "RDS instances" aws rds describe-db-instances --query 'length(DBInstances)'
  c bills "RDS/Aurora clusters" aws rds describe-db-clusters --query 'length(DBClusters)'
  c bills "Secrets Manager secrets (\$0.40/month each)" aws secretsmanager list-secrets --query 'length(SecretList)'
  c bills "GuardDuty detectors" aws guardduty list-detectors --query 'length(DetectorIds)'
  c bills "AWS Config recorders, recording" aws configservice describe-configuration-recorder-status --query 'length(ConfigurationRecordersStatus[?recording])'
  aws securityhub describe-hub --region "$r" >/dev/null 2>&1 && echo "bills $r Security Hub enabled 1"
  local k=0 kid
  for kid in $(aws kms list-keys --region "$r" --query 'Keys[].KeyId' --output text 2>/dev/null); do
    x=$(aws kms describe-key --region "$r" --key-id "$kid" --query '[KeyMetadata.KeyManager,KeyMetadata.KeyState]' --output text 2>/dev/null)
    [[ "$x" == CUSTOMER*Enabled* || "$x" == CUSTOMER*Disabled* ]] && k=$((k+1))
  done
  (( k )) && echo "bills $r KMS customer keys (\$1/month each; schedule deletion) $k"
  n=$(aws ecr describe-repositories --region "$r" --query 'repositories[].repositoryName' --output text 2>/dev/null)
  if [[ -n "$n" ]]; then
    local imgs=0 repo
    for repo in $n; do imgs=$((imgs + $(aws ecr list-images --region "$r" --repository-name "$repo" --query 'length(imageIds)' --output text 2>/dev/null || echo 0))); done
    (( imgs )) && echo "bills $r ECR images (storage, \$0.10/GB-month) $imgs in: $n" || echo "note $r ECR repositories, empty $n"
  fi
  x=$(aws logs describe-log-groups --region "$r" --query '[length(logGroups), sum(logGroups[].storedBytes)]' --output text 2>/dev/null)
  [[ -n "$x" && "${x%%[[:space:]]*}" != 0 ]] && echo "note $r CloudWatch log groups (count, bytes stored) ${x//[[:space:]]/ }"
  c note "Lambda functions" aws lambda list-functions --query 'length(Functions)'
  c note "ECS clusters" aws ecs list-clusters --query 'length(clusterArns)'
  c note "DynamoDB tables" aws dynamodb list-tables --query 'length(TableNames)'
  c note "CloudFormation stacks" aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED --query 'length(StackSummaries)'
  c note "non-default VPCs" aws ec2 describe-vpcs --filters Name=is-default,Values=false --query 'length(Vpcs)'
  c note "SNS topics" aws sns list-topics --query 'length(Topics)'
  n=$(aws resourcegroupstaggingapi get-resources --region "$r" --tag-filters Key=project,Values=bhn-sim --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)
  (( n )) && echo "tagged $r resources-tagged-project=bhn-sim $n"
  return 0
}
REGIONS=$(q aws ec2 describe-regions --query 'Regions[].RegionName' --output text)
[[ -n "$REGIONS" ]] || die "cannot list regions — SSO session expired? aws sso login --profile $AWS_PROFILE"
for r in $REGIONS; do region "$r" > "$T/r-$r.txt" & done; wait
CLEAN=0; TAGGED=""
for r in $REGIONS; do
  if [[ ! -s "$T/r-$r.txt" ]]; then CLEAN=$((CLEAN+1)); continue; fi
  while read -r kind rr rest; do
    case "$kind" in
      bills)  bills "$rr: $rest" ;;
      note)   note "$rr: $rest" ;;
      tagged) TAGGED="$TAGGED $rr" ;;
    esac
  done < "$T/r-$r.txt"
done
ok "$CLEAN of $(echo "$REGIONS" | wc -w) regions: nothing at all"

step "4 · Anything still tagged project=bhn-sim"
if [[ -z "$TAGGED" ]]; then ok "nothing tagged project=bhn-sim in any region"
else
  for r in $TAGGED; do
    q aws resourcegroupstaggingapi get-resources --region "$r" --tag-filters Key=project,Values=bhn-sim \
      --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' \
      | sed -E 's/^(arn:aws:s3:::.*)$/\1   (an S3 bucket: see section 2 — the state bucket is kept on purpose)/; s/^/     /' | mask
  done
  say "  (the tag index can lag a deleted resource by hours — re-check tomorrow before chasing one)"
fi

step "Verdict"
say "  $BILL thing(s) that bill while idle, $NOTE free leftover(s)"
(( BILL == 0 )) && ok "nothing in this account costs money while the lab is off" || { warn "delete the 'bills' lines (console or the Terraform root that made them)"; exit 1; }
