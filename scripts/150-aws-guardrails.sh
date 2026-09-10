#!/usr/bin/env bash
# Day 15, Steps 1–2 — money guardrails, then identity. The console parts cannot be scripted
# (and should not be: root + MFA + a budget are things you do with your own hands, once).
# This script does the parts that CAN be done from WSL and then VERIFIES the console parts
# through the API, so "I think I set the budget" becomes "the budget exists".
#
#   ./scripts/150-aws-guardrails.sh --install   install the AWS CLI v2 in WSL (the Mac says brew; we do not)
#   ./scripts/150-aws-guardrails.sh --sso       walk through `aws configure sso` for profile 'lab'
#   ./scripts/150-aws-guardrails.sh             verify: CLI, SSO session, root MFA, budget, region
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1

if [[ "${1:-}" == "--install" ]]; then
  step "AWS CLI v2 (official installer — WSL, not brew)"
  have aws && { ok "already installed: $(aws --version)"; exit 0; }
  have unzip || sudo apt-get install -y -q unzip >/dev/null
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$T/awscliv2.zip"
  ( cd "$T" && unzip -q awscliv2.zip && sudo ./aws/install >/dev/null )
  ok "$(aws --version)"
  exit 0
fi

if [[ "${1:-}" == "--sso" ]]; then
  step "IAM Identity Center (SSO) — short-lived credentials, the modern path"
  say "  In the console FIRST (once): IAM Identity Center > Enable (region $AWS_REGION) > Users > create yourself >"
  say "  AWS accounts > assign your user the AdministratorAccess permission set. Note the 'AWS access portal URL'."
  say "  Then answer the prompts: session name 'lab', the start URL, region $AWS_REGION, scopes default,"
  say "  pick the account and AdministratorAccess, CLI default region $AWS_REGION, output json, profile name 'lab'."
  echo
  aws configure sso --profile "$AWS_PROFILE"
  ok "profile '$AWS_PROFILE' configured — sessions expire (that is the feature): aws sso login --profile $AWS_PROFILE renews"
  exit 0
fi

step "AWS CLI"
have aws && ok "$(aws --version | cut -d' ' -f1)" || die "aws CLI missing — $0 --install"

step "Identity — profile '$AWS_PROFILE', region $AWS_REGION"
if ID=$(aws sts get-caller-identity --output json 2>/dev/null); then
  ACCT=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])' <<<"$ID")
  ARN=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])' <<<"$ID")
  ok "account $ACCT as $ARN"
  case "$ARN" in
    *:assumed-role/AWSReservedSSO_*) ok "SSO (short-lived credentials) — the preferred path" ;;
    *:user/*)  warn "an IAM user with a long-lived key — the documented fallback; note it in the README (leaked long-lived keys are among the most common real cloud incidents)" ;;
    *:root)    die "you are ROOT. Never for daily work. $0 --sso" ;;
  esac
else
  warn "no session: aws sso login --profile $AWS_PROFILE   (first time: $0 --sso)"; exit 1
fi
grep -q "^export AWS_PROFILE=" ~/.bashrc 2>/dev/null && ok "AWS_PROFILE exported in ~/.bashrc" \
  || { echo "export AWS_PROFILE=$AWS_PROFILE AWS_REGION=$AWS_REGION AWS_PAGER=" >> ~/.bashrc; ok "added AWS_PROFILE/AWS_REGION to ~/.bashrc (new shells)"; }

step "Guardrails — verified through the API, not remembered"
# Root MFA: IAM account summary is readable by an admin
MFA=$(aws iam get-account-summary --query 'SummaryMap.AccountMFAEnabled' --output text 2>/dev/null || echo '?')
[[ "$MFA" == 1 ]] && ok "root MFA enabled" || warn "root MFA NOT enabled — console as root > IAM > Add MFA for the root user, then put root away"
# Budget
B=$(aws budgets describe-budgets --account-id "$ACCT" --query 'Budgets[].[BudgetName,BudgetLimit.Amount,BudgetLimit.Unit]' --output text 2>/dev/null || true)
if [[ -n "$B" ]]; then
  ok "budget(s): $(echo "$B" | tr '\t' ' ' | tr '\n' ';')"
  NB=$(echo "$B" | head -1 | awk '{print $1}')
  N=$(aws budgets describe-notifications-for-budget --account-id "$ACCT" --budget-name "$NB" --query 'length(Notifications)' --output text 2>/dev/null || echo 0)
  (( N >= 2 )) && ok "  $N alert thresholds on '$NB' (50% and 80% expected)" || warn "  only $N alert threshold(s) on '$NB' — add 50% and 80% of actual, to an email you read"
else
  warn "NO budget — Billing and Cost Management > Budgets > Create: monthly cost, \$20, alerts at 50% and 80% ACTUAL, your email. The smoke detector. Do this before anything else."
fi
say "  Free Tier usage alerts: not readable through the API — confirm in Billing > Billing preferences (Alert preferences) and tick it in DAY15.md"
# Cost Explorer enabled? (a CE call costs $0.01; one is fine)
if aws ce get-cost-and-usage --time-period "Start=$(date -d '1 day ago' +%F),End=$(date +%F)" --granularity DAILY --metrics UnblendedCost --output text >/dev/null 2>&1; then
  ok "Cost Explorer answers (data lags ~24 h)"
else
  warn "Cost Explorer not enabled yet — Billing > Cost Explorer > Enable (it takes up to 24 h to fill; 154-aws-cost.sh reads it)"
fi

step "Tools for the rest of the day"
have terraform && ok "terraform $(terraform version -json | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])')" || die "terraform missing"
python3 - <<'PY' || die "terraform >= 1.10 required (S3-native state locking) — sudo apt-get install --only-upgrade terraform"
import json,subprocess,sys; v=json.loads(subprocess.check_output(["terraform","version","-json"]))["terraform_version"]
sys.exit(0 if tuple(int(x) for x in v.split(".")[:2])>=(1,10) else 1)
PY
docker buildx version >/dev/null 2>&1 && ok "docker buildx (cross-platform builds; --platform linux/amd64 for EKS nodes)" || die "docker buildx missing — Docker Desktop > Settings > Docker Engine"
ok "Next: ./scripts/151-aws-state.sh"
