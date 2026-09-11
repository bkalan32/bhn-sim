#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 16 exit criteria"
aws sts get-caller-identity >/dev/null 2>&1 && t_ok "AWS session (SSO)" || { t_fail "no AWS session — aws sso login --profile $AWS_PROFILE"; exit 1; }

# code
for f in infra/aws/eks/eks.tf infra/aws/eks/pod-identity.tf infra/aws/eks/backend.tf infra/aws/platform/releases.tf infra/aws/platform/providers.tf infra/aws/platform/tf.sh k8s/kps-values-eks.yaml k8s/fluent-bit-cloudwatch.yaml.tmpl; do
  [[ -f "$f" ]] && t_ok "$f" || t_fail "$f missing"
done
grep -q 'capacity_type *= *"SPOT"' infra/aws/eks/eks.tf && grep -q 'addons *= *{' infra/aws/eks/eks.tf && t_ok "eks.tf: SPOT node group, add-ons declared (v21 installs none by itself)" || t_fail "eks.tf missing SPOT or the addons block"
grep -q 'pods.eks.amazonaws.com' infra/aws/eks/pod-identity.tf && t_ok "pod identity roles (EBS CSI, Fluent Bit) — no node-role borrowing" || t_fail "pod-identity.tf incomplete"
grep -q 'key *= *"platform/terraform.tfstate"' infra/aws/platform/versions.tf && grep -q 'key *= *"eks/terraform.tfstate"' infra/aws/eks/backend.tf && t_ok "three roots, three state keys (env / eks / platform)" || t_fail "state keys not separated"
grep -q 'config_context' infra/aws/platform/providers.tf && grep -q 'aws-lab' infra/aws/platform/providers.tf && t_ok "platform providers pinned to context aws-lab" || t_fail "platform providers not pinned to aws-lab"
grep -q 'cloudwatch_logs' k8s/fluent-bit-cloudwatch.yaml.tmpl && ! grep -qE 'Splunk_Token|aws_secret|secretKeyRef' k8s/fluent-bit-cloudwatch.yaml.tmpl && t_ok "Fluent Bit -> CloudWatch, no credential in values" || t_fail "fluent-bit-cloudwatch values wrong"
grep -q 'kubeScheduler' k8s/kps-values-eks.yaml && t_ok "kps EKS overlay: control-plane scrapes off" || t_fail "k8s/kps-values-eks.yaml missing the control-plane switches"
N=$(ls k8s/aws/*.yaml 2>/dev/null | wc -l); (( N == 5 )) && t_ok "k8s/aws: five rendered manifests" || t_fail "k8s/aws has $N manifests (163 --render)"
(( N == 5 )) && { grep -l 'dkr.ecr' k8s/aws/*.yaml | wc -l | grep -cx 5 >/dev/null && t_ok "every k8s/aws image is an ECR URL" || t_fail "a k8s/aws manifest does not pull from ECR"; }
(( N == 5 )) && { D=$(diff -r k8s k8s/aws 2>/dev/null | grep -cE '^> .*(image:)' || true); (( D >= 5 )) && t_ok "diff k8s vs k8s/aws: image lines are the change ($D)" || t_fail "k8s/aws differs from k8s in unexpected ways"; }
grep -q 'KUBE_CONTEXT:-kind' scripts/lib.sh && t_ok "lib.sh: KUBE_CONTEXT=aws-lab runs every script against EKS" || t_fail "lib.sh not context-switchable"

# what happened
[[ -f checkpoints/day16-eks-applied.txt ]] && t_ok "EKS applied ($(cat checkpoints/day16-eks-applied.txt))" || t_fail "EKS never applied (160 apply)"
[[ -f checkpoints/day16-platform-applied.txt ]] && t_ok "platform applied on EKS ($(cat checkpoints/day16-platform-applied.txt))" || t_fail "platform never applied on EKS (162)"
[[ -f incidents/INC-0018-diagnosis.md ]] && grep -q 'ai_hypothesis' incidents/INC-0018-diagnosis.md && t_ok "INC-0018 drill ran on EKS (diagnosis file)" || t_fail "no incidents/INC-0018-diagnosis.md (165)"
[[ -f incidents/INC-0018.md ]] && t_ok "incidents/INC-0018.md written" || t_fail "write incidents/INC-0018.md (template shipped)"
grep -qE '^\| 0018 \|' docs/ops-kpis.md && t_ok "ops-kpis.md row 0018" || t_fail "docs/ops-kpis.md needs row 0018"
grep -q 'Eval 7' docs/ai-eval.md && t_ok "ai-eval.md Eval 7 (the hypothesis with one collector missing)" || t_fail "docs/ai-eval.md needs Eval 7"
# eks-notes: six rows with words in the "in my words" column
W=$(awk -F'|' '/^\| [1-6] \|/ {c=$4; gsub(/^[ \t]+|[ \t]+$/,"",c); if (length(c)>15) n++} END {print n+0}' docs/eks-notes.md)
(( W >= 6 )) && t_ok "docs/eks-notes.md: six differences in your words" || t_fail "docs/eks-notes.md: $W of 6 rows have your one line (the evidence block is generated; the words are yours)"
grep -q 'evidence:start' docs/eks-notes.md && t_ok "eks-notes evidence block (166)" || t_fail "run ./scripts/166-eks-differences.sh"

# destroyed, verified
if [[ -f checkpoints/day16-torn-down.txt ]]; then
  C=$(aws eks list-clusters --query 'length(clusters)' --output text 2>/dev/null || echo ?)
  [[ "$C" == 0 ]] && t_ok "no EKS cluster ($(cat checkpoints/day16-torn-down.txt))" || t_fail "$C EKS cluster(s) still exist"
  I=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running,pending,stopped" --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo ?)
  [[ "$I" == 0 ]] && t_ok "no EC2 instances" || t_fail "$I instance(s) still exist"
  L=$(aws elbv2 describe-load-balancers --query 'length(LoadBalancers)' --output text 2>/dev/null || echo ?)
  [[ "$L" == 0 ]] && t_ok "no load balancers" || t_fail "$L load balancer(s) — the orphan the PDF warns about"
  aws logs describe-log-groups --log-group-name-prefix /bhn-sim/containers --query 'length(logGroups)' --output text 2>/dev/null | grep -cx 0 >/dev/null && t_ok "CloudWatch lab log group removed" || t_fail "/bhn-sim/containers still exists"
  ./scripts/155-aws-verify-destroyed.sh >/dev/null 2>&1 && t_ok "155: nothing billing anywhere" || warn "155 lists leftovers — the NAT/EIP are the env root if you kept it (167 --all removes them); anything else is real"
else t_fail "not torn down yet (./scripts/167-eks-teardown.sh)"; fi
grep -qE '^\| 16[^|]*\|[^|]*\|[^|]*\| *\$[0-9]' docs/aws-costs.md && t_ok "docs/aws-costs.md has a Day 16 row with a real cost" || t_fail "docs/aws-costs.md row 16 has no cost yet (154-aws-cost.sh --row 16, tomorrow morning)"
git status --porcelain 2>/dev/null | grep -c . >/dev/null && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 16 done." || { warn "Not done yet."; exit 1; }
