#!/usr/bin/env bash
# Day 15, Steps 4–5 — the environment root: VPC (+ one NAT gateway: the meter starts) and
# the five ECR repositories. Plan, READ, apply — and destroy when you pause, because the
# NAT bills by the hour whether or not anything uses it.
#
#   ./scripts/152-aws-vpc.sh plan      what would be created, summarised by kind
#   ./scripts/152-aws-vpc.sh apply     create it; verify subnets, NAT, tags, repos through the API
#   ./scripts/152-aws-vpc.sh destroy   pausing? remove everything the root created; then 155 verifies
#   ./scripts/152-aws-vpc.sh status    what exists right now, and what it costs per hour
source "$(dirname "$0")/lib.sh"
require_aws
cd "$LAB_ROOT" || exit 1
[[ -f "$AWS_ENV/backend.hcl" ]] || die "no infra/aws/env/backend.hcl — ./scripts/151-aws-state.sh first"

summarise_plan() {  # plan.txt -> counts by resource type and action
  python3 - "$1" <<'PY'
import re, sys, collections
c = collections.Counter()
for m in re.finditer(r'# (\S+) will be (created|destroyed|updated|replaced)', open(sys.argv[1]).read()):
    addr, act = m.groups()
    typ = next((p for p in addr.split('.') if p.startswith('aws_')), addr)
    c[(act, typ.split('[')[0])] += 1
for (act, typ), n in sorted(c.items()):
    print("  %-9s %-40s x%d" % (act, typ, n))
PY
}

case "${1:-}" in
  plan)
    step "terraform plan — infra/aws/env (VPC, subnets, route tables, IGW, one NAT + EIP, five ECR repos)"
    tf_aws "$AWS_ENV" plan -input=false -no-color -var "region=$AWS_REGION" -out=env.tfplan > "$AWS_ENV/plan.txt" 2>&1 || { tail -15 "$AWS_ENV/plan.txt"; die "plan failed"; }
    summarise_plan "$AWS_ENV/plan.txt"
    grep -E '^Plan:' "$AWS_ENV/plan.txt" | sed 's/^/  /'
    say ""
    say "  Read for: exactly ONE aws_nat_gateway and ONE aws_eip (single_nat_gateway); two public + two private"
    say "  subnets in two AZs; the kubernetes.io/role tags on both subnet groups; five aws_ecr_repository."
    ok "Next: $0 apply   (the NAT meter starts on apply: ~\$0.045/h + data; ~\$1.10/day idle)"
    ;;
  apply)
    step "terraform apply — infra/aws/env"
    [[ -f "$AWS_ENV/env.tfplan" ]] || die "no saved plan — $0 plan first, and read it"
    tf_aws "$AWS_ENV" apply -input=false -no-color env.tfplan > "$AWS_ENV/apply.txt" 2>&1 || { grep -E 'Error' -A4 "$AWS_ENV/apply.txt" | head -12; die "apply failed — infra/aws/env/apply.txt"; }
    rm -f "$AWS_ENV/env.tfplan"
    grep -E '^Apply complete' "$AWS_ENV/apply.txt" | sed 's/^/  /'
    date -u +%FT%TZ > "$LAB_ROOT/checkpoints/day15-vpc-applied.txt"
    echo "VPC (2 public + 2 private subnets), 1 NAT gateway + EIP, 5 ECR repos — no compute" > "$LAB_ROOT/checkpoints/day15-what-ran.txt"

    step "Proving it through the API"
    VPC=$(tf_aws "$AWS_ENV" output -raw vpc_id)
    ok "VPC $VPC"
    aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
      --query 'Subnets[].[AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,join(`,`,Tags[?starts_with(Key,`kubernetes.io/role`)].Key)]' --output text \
      | sort | awk '{printf "  %-14s %-16s auto-ip=%-5s %s\n",$1,$2,$3,$4}'
    N=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" "Name=state,Values=available,pending" --query 'length(NatGateways)' --output text)
    [[ "$N" == 1 ]] && ok "exactly one NAT gateway ($(tf_aws "$AWS_ENV" output -raw nat_public_ip)) — the cost decision, in effect" || warn "$N NAT gateways (expected 1)"
    R=$(aws ecr describe-repositories --query 'length(repositories[?starts_with(repositoryName,`bhn-sim/`)])' --output text)
    [[ "$R" == 5 ]] && ok "five ECR repositories (scan on push, lifecycle: last 10 tagged)" || warn "$R ECR repos (expected 5)"
    echo
    say "  THE METER IS RUNNING: NAT ~\$0.045/h + \$0.045/GB. Not continuing to Day 16 tomorrow? $0 destroy tonight."
    ok "Next: ./scripts/153-aws-ecr-push.sh"
    ;;
  destroy)
    step "terraform destroy — infra/aws/env (VPC, NAT, EIP, subnets, ECR repos + their images)"
    say "  Keeps: the S3 state bucket (pennies), SSO, the budget. Re-apply is five minutes; that round trip is the muscle."
    read -rp "  Destroy? [type yes] " a; [[ "$a" == yes ]] || die "not destroying"
    tf_aws "$AWS_ENV" destroy -input=false -auto-approve -no-color -var "region=$AWS_REGION" > "$AWS_ENV/apply.txt" 2>&1 || { grep -E 'Error' -A4 "$AWS_ENV/apply.txt" | head -12; die "destroy failed — usually an orphan (a load balancer or ENI) — infra/aws/env/apply.txt, then ./scripts/155-aws-verify-destroyed.sh"; }
    grep -E '^Destroy complete' "$AWS_ENV/apply.txt" | sed 's/^/  /'
    date -u +%FT%TZ > "$LAB_ROOT/checkpoints/day15-vpc-destroyed.txt"
    "$LAB_ROOT/scripts/155-aws-verify-destroyed.sh"
    ;;
  status)
    step "What exists (region $AWS_REGION)"
    aws ec2 describe-vpcs --filters "Name=tag:project,Values=bhn-sim" --query 'Vpcs[].[VpcId,CidrBlock]' --output text | sed 's/^/  vpc  /'
    N=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available,pending" --query 'length(NatGateways)' --output text); say "  NAT gateways: $N   (each ~\$1.10/day idle)"
    E=$(aws ec2 describe-addresses --query 'length(Addresses)' --output text); say "  elastic IPs: $E"
    R=$(aws ecr describe-repositories --query 'repositories[?starts_with(repositoryName,`bhn-sim/`)].repositoryName' --output text | wc -w); say "  ECR repos: $R"
    I=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending" --query 'length(Reservations[].Instances[])' --output text); say "  EC2 instances running: $I"
    ;;
  *) die "usage: $0 plan|apply|destroy|status" ;;
esac
