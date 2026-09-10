#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 15 exit criteria"
have aws && t_ok "aws CLI" || t_fail "aws CLI missing"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ARN=$(aws sts get-caller-identity --query Arn --output text); ACCT=$(aws_account)
  case "$ARN" in *AWSReservedSSO_*) t_ok "identity via SSO (short-lived): ${ARN##*/}";; *:user/*) t_ok "identity: IAM user (documented fallback) ${ARN##*/}"; grep -qi 'fallback' README.md && t_ok "README notes the fallback" || t_fail "README must note why SSO is preferred";; *) t_fail "identity is $ARN";; esac
else t_fail "no AWS session — aws sso login --profile $AWS_PROFILE"; exit 1; fi
[[ "$(aws iam get-account-summary --query 'SummaryMap.AccountMFAEnabled' --output text 2>/dev/null)" == 1 ]] && t_ok "root MFA enabled" || t_fail "root MFA not enabled"
NB=$(aws budgets describe-budgets --account-id "$ACCT" --query 'length(Budgets)' --output text 2>/dev/null || echo 0)
(( NB >= 1 )) && t_ok "budget exists ($NB)" || t_fail "no budget"
grep -qE '\[x\] Free Tier' DAY15.md && t_ok "free-tier alerts ticked in DAY15.md" || t_fail "tick '[x] Free Tier' in DAY15.md once enabled (not readable via API)"
# state
B=$(grep -oE 'bucket *= *"[^"]+"' infra/aws/env/backend.hcl 2>/dev/null | cut -d'"' -f2)
[[ -n "$B" ]] && t_ok "backend.hcl -> $B" || t_fail "no infra/aws/env/backend.hcl — 151"
if [[ -n "$B" ]]; then
  [[ "$(aws s3api get-bucket-versioning --bucket "$B" --query Status --output text 2>/dev/null)" == Enabled ]] && t_ok "bucket versioned" || t_fail "bucket not versioned"
  aws s3api get-public-access-block --bucket "$B" >/dev/null 2>&1 && t_ok "bucket public access blocked" || t_fail "no public access block"
  aws s3 ls "s3://$B/env/terraform.tfstate" >/dev/null 2>&1 && t_ok "env state lives in S3" || t_fail "s3://$B/env/terraform.tfstate missing"
  git check-ignore -q infra/aws/backend/terraform.tfstate && t_ok "backend root's local state gitignored" || t_fail "infra/aws/backend/terraform.tfstate not ignored"
fi
grep -q 'use_lockfile *= *true' infra/aws/env/backend.tf && t_ok "S3-native locking (use_lockfile)" || t_fail "use_lockfile missing"
# vpc + ecr: applied, OR destroyed for the pause with proof
N=$(aws ec2 describe-nat-gateways --filter 'Name=state,Values=available' --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)
R=$(aws ecr describe-repositories --query 'length(repositories[?starts_with(repositoryName,`bhn-sim/`)])' --output text 2>/dev/null || echo 0)
if [[ -f checkpoints/day15-vpc-applied.txt ]]; then
  if [[ -f checkpoints/day15-vpc-destroyed.txt && checkpoints/day15-vpc-destroyed.txt -nt checkpoints/day15-vpc-applied.txt ]]; then
    ./scripts/155-aws-verify-destroyed.sh >/dev/null 2>&1 && t_ok "VPC applied ($(cat checkpoints/day15-vpc-applied.txt)) then destroyed for the pause — nothing billing" || t_fail "destroyed, but something still bills — ./scripts/155-aws-verify-destroyed.sh"
    grep -q 'ECR.*pushed\|pushed.*ECR' checkpoints/day15-ecr-pushed.txt 2>/dev/null && t_ok "images were pushed before the destroy ($(head -1 checkpoints/day15-ecr-pushed.txt))" || t_fail "no record of the ECR push — checkpoints/day15-ecr-pushed.txt"
  else
    [[ "$N" == 1 ]] && t_ok "VPC up with exactly one NAT gateway (the meter is running)" || t_fail "$N NAT gateways (expected 1 while up)"
    [[ "$R" == 5 ]] && t_ok "five ECR repositories" || t_fail "$R ECR repos"
    ok_imgs=0; for s in activation egift settlement incident-bot remediator; do n=$(aws ecr describe-images --repository-name "bhn-sim/$s" --query 'length(imageDetails)' --output text 2>/dev/null || echo 0); (( n >= 1 )) && ok_imgs=$((ok_imgs+1)); done
    (( ok_imgs == 5 )) && t_ok "every repo holds at least one image" || t_fail "$ok_imgs of 5 repos have images — ./scripts/153-aws-ecr-push.sh"
  fi
else t_fail "VPC never applied — ./scripts/152-aws-vpc.sh plan|apply"; fi
grep -q 'single_nat_gateway *= *true' infra/aws/env/vpc.tf && grep -q 'kubernetes.io/role/elb' infra/aws/env/vpc.tf && t_ok "vpc.tf: single NAT (commented) + subnet role tags" || t_fail "vpc.tf missing the NAT trade-off or the subnet tags"
[[ -x scripts/153-aws-ecr-push.sh ]] && grep -q 'linux/amd64' scripts/153-aws-ecr-push.sh && t_ok "push loop builds --platform linux/amd64" || t_fail "push script missing"
# docs
grep -q '## AWS' README.md && grep -q 'sso login' README.md && grep -q 'terraform destroy\|152-aws-vpc.sh destroy' README.md && t_ok "README: AWS section (login, state bucket, apply/destroy, push loop, the rule)" || t_fail "README lacks the AWS section"
grep -qE '^\| 15 \| .*\| *\$[0-9]' docs/aws-costs.md && t_ok "docs/aws-costs.md has Day 15's real cost" || t_fail "docs/aws-costs.md row 15 has no cost yet (154-aws-cost.sh --row 15, tomorrow morning when Cost Explorer has caught up)"
git status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 15 done." || { warn "Not done yet."; exit 1; }
