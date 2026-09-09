#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
TF="$LAB_ROOT/infra/local/tf.sh"
step "Day 13 exit criteria"

# the code describes all of it
for f in versions.tf providers.tf variables.tf namespaces.tf releases.tf chart-versions.auto.tfvars tf.sh; do
  [[ -s infra/local/$f ]] && t_ok "infra/local/$f" || t_fail "infra/local/$f missing"
done
n=$(grep -c 'resource "kubernetes_namespace"' infra/local/namespaces.tf); [[ "$n" == 4 ]] && t_ok "four namespaces declared" || t_fail "expected 4 namespaces, found $n"
n=$(grep -c 'resource "helm_release"' infra/local/releases.tf); [[ "$n" == 5 ]] && t_ok "five Helm releases declared" || t_fail "expected 5 releases, found $n"
grep -q 'version *= *var.chart_versions' infra/local/releases.tf && t_ok "every release pinned to chart-versions.auto.tfvars" || t_fail "releases are not pinned"
grep -q 'kind: Namespace' k8s/activation.yaml && t_fail "payments Namespace still declared in k8s/activation.yaml (two owners)" || t_ok "payments Namespace has one owner (Terraform)"

# imported and clean
if [[ -f infra/local/terraform.tfstate ]]; then
  n=$("$TF" state list 2>/dev/null | grep -cE '^(kubernetes_namespace|helm_release)\.' || true)
  [[ "$n" == 9 ]] && t_ok "state holds all 9 resources (imported, not recreated)" || t_fail "state holds $n of 9 resources — ./scripts/130-tf-import.sh"
  set +e; "$TF" plan -input=false -detailed-exitcode -lock=false >/dev/null 2>&1; RC=$?; set -e
  case "$RC" in 0) t_ok "terraform plan is clean (exit 0)";; 2) t_fail "terraform plan shows DRIFT (exit 2) — ./infra/local/tf.sh plan";; *) t_fail "terraform plan failed (exit $RC)";; esac
else
  t_fail "no state file — ./scripts/130-tf-import.sh"
fi
git check-ignore -q infra/local/terraform.tfstate && t_ok "state is gitignored (state is not code)" || t_fail "infra/local/terraform.tfstate is NOT ignored"
git ls-files --error-unmatch infra/local/chart-versions.auto.tfvars >/dev/null 2>&1 && t_ok "chart pins are committed" || t_fail "chart-versions.auto.tfvars not committed"

# the change and the drift, on the record
grep -q 'repeat_interval: 6h' k8s/kps-values.yaml && git log --oneline -- k8s/kps-values.yaml | grep -qi 'repeat_interval' \
  && t_ok "one real change went edit-plan-apply-commit (repeat_interval 6h)" || t_fail "the repeat_interval change is not in k8s/kps-values.yaml with a commit"
alertmanager_get /api/v2/status | grep -q 'repeat_interval: 6h' && t_ok "Alertmanager's live config says 6h" || t_fail "Alertmanager does not show repeat_interval: 6h"
[[ -f checkpoints/day13-drift-injected.txt ]] && t_ok "drift was injected ($(cat checkpoints/day13-drift-injected.txt))" || t_fail "no evidence of the drift drill — ./scripts/132-drift-drill.sh inject"
k get servicemonitor -n "$MONITORING_NS" 2>/dev/null | grep -q pushgateway && t_ok "drift repaired: pushgateway ServiceMonitor present" || t_fail "pushgateway ServiceMonitor missing — drift not repaired"

# deterministic and secret-free (B8, B9, B10)
grep -q 'manifest *= *true' infra/local/providers.tf && t_ok "helm provider compares live manifests (drift is visible)" || t_fail "providers.tf lacks experiments = { manifest = true } — plan cannot see drift"
grep -q 'existingSecret: grafana-admin' k8s/kps-values.yaml && k get secret grafana-admin -n "$MONITORING_NS" >/dev/null 2>&1 && t_ok "Grafana password in our Secret (plan deterministic)" || t_fail "Grafana admin password still chart-generated — ./scripts/134-tf-deterministic.sh"
if [[ -f infra/local/terraform.tfstate ]] && k get secret splunk-hec -n "$LOGGING_NS" >/dev/null 2>&1; then
  T=$(k get secret splunk-hec -n "$LOGGING_NS" -o jsonpath='{.data.token}' | base64 -d); grep -q -- "$T" infra/local/terraform.tfstate && t_fail "HEC token is in terraform.tfstate" || t_ok "no HEC token in state"; unset T
else t_fail "secret/splunk-hec missing — ./scripts/134-tf-deterministic.sh"; fi

# the nightly job
[[ -s ci/Jenkinsfile.drift && -s ci/infra-drift-check.job.xml ]] && t_ok "ci/Jenkinsfile.drift + job XML" || t_fail "drift job files missing"
grep -q terraform ci/Dockerfile.jenkins && t_ok "Jenkins image installs terraform" || t_fail "ci/Dockerfile.jenkins lacks terraform"
if curl -fsS -o /dev/null http://localhost:8081/job/infra-drift-check/api/json 2>/dev/null || curl -s -o /dev/null -w '%{http_code}' http://localhost:8081/job/infra-drift-check/ | grep -qE '^(200|403)$'; then
  t_ok "Jenkins job infra-drift-check exists"
else
  t_fail "Jenkins job infra-drift-check not found — ./scripts/133-drift-check-job.sh"
fi

# the write-up
[[ -s incidents/INC-0015.md ]] && ! grep -q '_fill in_' incidents/INC-0015.md && t_ok "INC-0015.md written" || t_fail "incidents/INC-0015.md incomplete"
grep -q 'Terraform owns' README.md && t_ok "README states the ownership boundary" || t_fail "README lacks the ownership boundary"
git status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 13 done." || { warn "Not done yet."; exit 1; }
