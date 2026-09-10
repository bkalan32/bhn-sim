#!/usr/bin/env bash
# Day 15, Step 3 — remote state. Day 13's state lived on the laptop, flagged as a shortcut.
# In a team, state is shared and locked. Terraform >= 1.10 locks in S3 itself (use_lockfile),
# so no DynamoDB table — older tutorials (and older Terraform) still show one.
#
#   1. infra/aws/backend  — creates the versioned, private, encrypted bucket (LOCAL state:
#      the bucket that holds everyone's state cannot hold its own; its state names one bucket
#      and holds no secret)
#   2. writes the bucket name + region into infra/aws/env/backend.hcl (committed — it is
#      configuration, not a secret) and infra/aws/platform/backend.hcl for Day 16
#   3. inits infra/aws/env against it and proves the bucket's properties through the API
source "$(dirname "$0")/lib.sh"
require_aws
cd "$LAB_ROOT" || exit 1

step "State bucket (infra/aws/backend, local state on purpose)"
terraform -chdir="$AWS_BACKEND_ROOT" init -input=false >/dev/null && ok "init"
terraform -chdir="$AWS_BACKEND_ROOT" apply -input=false -auto-approve -var "region=$AWS_REGION" > "$AWS_BACKEND_ROOT/apply.txt" 2>&1 \
  || die "apply failed: $(grep -E 'Error' -A3 "$AWS_BACKEND_ROOT/apply.txt" | head -8)"
BUCKET=$(terraform -chdir="$AWS_BACKEND_ROOT" output -raw bucket)
ok "bucket: $BUCKET ($AWS_REGION)"

step "Proving the bucket's properties (the API, not the plan)"
V=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null || echo none)
[[ "$V" == Enabled ]] && ok "versioning Enabled — every state write is recoverable" || die "versioning is '$V'"
PAB=$(aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("all" if all(d.values()) else "partial")' 2>/dev/null || echo none)
[[ "$PAB" == all ]] && ok "public access blocked (all four)" || die "public access block is '$PAB'"
ENC=$(aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo none)
ok "encryption at rest: $ENC"

step "Backend config for the environment roots"
for root in env platform; do
  mkdir -p "$LAB_ROOT/infra/aws/$root"
  cat > "$LAB_ROOT/infra/aws/$root/backend.hcl" <<HCL
# written by scripts/151-aws-state.sh — the state bucket from infra/aws/backend. Committed:
# this is configuration, not a secret. The key is fixed in the root's backend.tf.
bucket = "$BUCKET"
region = "$AWS_REGION"
HCL
  ok "infra/aws/$root/backend.hcl"
done

step "terraform init for infra/aws/env against S3"
terraform -chdir="$AWS_ENV" init -input=false -reconfigure -backend-config=backend.hcl > "$AWS_ENV/init.txt" 2>&1 \
  || die "init failed: $(tail -8 "$AWS_ENV/init.txt")"
grep -q 'Successfully configured the backend "s3"' "$AWS_ENV/init.txt" || grep -q 'successfully initialized' "$AWS_ENV/init.txt" || warn "read $AWS_ENV/init.txt"
ok "backend s3://$BUCKET/env/terraform.tfstate, locked with use_lockfile (no DynamoDB)"
rm -f "$AWS_ENV/init.txt"

step "Commit"
say "  git add infra/aws .gitignore && git commit -m 'Day 15: S3 state bucket (versioned, private, S3-native locking); env root'"
ok "Next: ./scripts/152-aws-vpc.sh plan"
