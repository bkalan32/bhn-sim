#!/usr/bin/env bash
# Rebuild (23 Sep 2026) — the platform layer onto an EMPTY kind cluster, in the order that
# works. Everything Day 13 built assumes the releases already exist (they were imported);
# on a fresh cluster the same Terraform fails three different ways, each found by hand on
# the rebuild after the Docker wipe (CORRECTIONS-REBUILD B1–B3):
#
#   B1  the kps release mounts three Secrets Terraform does not own (grafana-admin,
#       newrelic-license x2) — missing, the apply hangs 15 min on ContainerCreating. They
#       need namespaces, and Terraform owns the namespaces: so namespaces FIRST (targeted).
#   B2  experiments.manifest = true makes every plan a server-side dry run; a dry run
#       installs nothing, so on an empty cluster "no matches for kind Prometheus … ensure
#       CRDs are installed first" (Day 16 B11, now on kind). The Operator's CRDs go in from
#       the SAME pinned chart, with create (not apply: the prometheuses CRD is over the
#       client-side annotation limit).
#   B3  the first install of kps and of the New Relic bundle ends "Provider produced
#       inconsistent result after apply" (admission webhooks stamp objects the dry run
#       never sees — Day 16 D6). The releases are fine; Terraform taints them. Untaint,
#       re-apply (no-op or in-place), and the plan after that must be clean.
#
#   ./scripts/135-platform-from-zero.sh          do it (prompts for the two secrets it needs)
#   ./scripts/135-platform-from-zero.sh --check  what exists, what is missing; no changes
#
# Prerequisites: 03-cluster-up.sh, 21-splunk-up.sh + a HEC token (22-fluent-bit.sh <TOKEN>
# is run by this script if secret/splunk-hec is missing), 50-jenkins-rebuild.sh.
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"
CHECK=0; [[ "${1:-}" == "--check" ]] && CHECK=1
KPS_VER=$(grep -oE '"kps" *= *"[0-9.]+"' infra/local/chart-versions.auto.tfvars | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[[ -n "$KPS_VER" ]] || die "no kps version in infra/local/chart-versions.auto.tfvars"

has_secret() { k get secret "$1" -n "$2" >/dev/null 2>&1; }
report() {
  step "What exists"
  for ns in payments monitoring tracing logging newrelic; do
    k get ns "$ns" >/dev/null 2>&1 && ok "namespace $ns" || warn "namespace $ns missing"; done
  has_secret grafana-admin monitoring && ok "secret/grafana-admin (monitoring)" || warn "secret/grafana-admin missing"
  has_secret newrelic-license monitoring && has_secret newrelic-license newrelic && ok "secret/newrelic-license (monitoring + newrelic)" || warn "secret/newrelic-license missing in one or both namespaces"
  has_secret splunk-hec logging && ok "secret/splunk-hec (logging)" || warn "secret/splunk-hec missing"
  N=$(k get crd 2>/dev/null | grep -c monitoring.coreos.com || true)
  (( N >= 10 )) && ok "$N Prometheus Operator CRDs" || warn "$N Prometheus Operator CRDs (expect 10)"
}
report
(( CHECK )) && exit 0

step "1/5  Namespaces (targeted apply — Terraform owns them; no chart is dry-run)"
"$TF" apply -input=false -auto-approve -no-color \
  -target=kubernetes_namespace.payments -target=kubernetes_namespace.monitoring \
  -target=kubernetes_namespace.tracing -target=kubernetes_namespace.logging \
  -target=kubernetes_namespace.newrelic > infra/local/apply.txt 2>&1 \
  || { grep -A6 '^Error' infra/local/apply.txt | head -12; die "namespace apply failed"; }
ok "five namespaces"

step "2/5  The Secrets the releases mount (kubectl, outside Terraform — never in state)"
if ! has_secret grafana-admin monitoring; then
  say "  Grafana's admin password is yours to choose on a new cluster (the chart uses it via existingSecret)."
  read -rsp "  Grafana admin password (not shown): " PW; echo
  [[ -n "$PW" ]] || die "empty password"
  k create secret generic grafana-admin -n monitoring --from-literal=admin-user=admin --from-literal=admin-password="$PW" >/dev/null
  unset PW; ok "secret/grafana-admin"
else ok "secret/grafana-admin exists"; fi
if ! has_secret newrelic-license monitoring || ! has_secret newrelic-license newrelic; then
  "$LAB_ROOT/scripts/170-newrelic-secret.sh" || die "no New Relic key stored — Prometheus's remote write mounts it"
else ok "secret/newrelic-license exists (both namespaces)"; fi
if ! has_secret splunk-hec logging; then
  read -rsp "  Splunk HEC token (not shown; Splunk > Settings > Data Inputs > HTTP Event Collector): " HEC; echo
  "$LAB_ROOT/scripts/22-fluent-bit.sh" "$HEC" | grep -E '^\s*(ok|warn|FAIL)' || true
  unset HEC
  has_secret splunk-hec logging || die "secret/splunk-hec still missing"
else ok "secret/splunk-hec exists"; fi

step "3/5  Prometheus Operator CRDs from the pinned chart ($KPS_VER)"
N=$(k get crd 2>/dev/null | grep -c monitoring.coreos.com || true)
if (( N >= 10 )); then ok "$N CRDs already present"; else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  helm pull prometheus-community/kube-prometheus-stack --version "$KPS_VER" -d "$T" >/dev/null || die "helm pull failed"
  tar -xzf "$T"/kube-prometheus-stack-"$KPS_VER".tgz -C "$T" --wildcards '*/charts/crds/crds/crd-*.yaml' || die "no CRDs in the chart"
  for f in "$T"/kube-prometheus-stack/charts/crds/crds/crd-*.yaml; do
    k get -f "$f" >/dev/null 2>&1 || k create -f "$f" >/dev/null || die "create failed: $(basename "$f")"
  done
  ok "$(k get crd | grep -c monitoring.coreos.com) CRDs"
fi

step "4/5  terraform apply — six releases (~10 min; kps pulls ~7 images)"
set +e; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1; RC=$?; set -e
if (( RC != 0 )); then
  TAINTED=$(grep -oE 'applying changes to helm_release\.[a-z_]+' infra/local/apply.txt | sed 's/.*\.//' | sort -u || true)
  OTHER=$(grep -E '^Error' infra/local/apply.txt | grep -vc 'inconsistent result after apply' || true)
  (( OTHER == 0 )) && [[ -n "$TAINTED" ]] || { grep -A8 '^Error' infra/local/apply.txt | head -30; die "apply failed for a reason that is not the first-install ghost — infra/local/apply.txt"; }
  for r in $TAINTED; do "$TF" untaint "helm_release.$r" >/dev/null && ok "untainted $r (first-install ghost, B3)"; done
  # the releases waiting on a tainted kps never ran: apply again; repeat once for the bundle
  for pass in 1 2; do
    set +e; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1; RC=$?; set -e
    (( RC == 0 )) && break
    for r in $(grep -oE 'applying changes to helm_release\.[a-z_]+' infra/local/apply.txt | sed 's/.*\.//' | sort -u || true); do
      "$TF" untaint "helm_release.$r" >/dev/null && ok "untainted $r"; done
  done
  (( RC == 0 )) || { grep -A8 '^Error' infra/local/apply.txt | head -30; die "apply still failing — infra/local/apply.txt"; }
fi
grep -E '^Apply complete' infra/local/apply.txt | sed 's/^/  /'

step "5/5  The plan after must be empty — the drift check's definition of done"
set +e; "$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1; RC=$?; set -e
case "$RC" in
  0) ok "No changes — the cluster matches infra/local" ;;
  2) grep -E '^\s+# .*(will be|must be)' infra/local/plan.txt | sed 's/^\s*/  /'; die "plan not clean — read infra/local/plan.txt; a 'must be replaced' is a taint left behind" ;;
  *) tail -5 infra/local/plan.txt; die "plan failed" ;;
esac
report
ok "Next: the application layer — docs/rebuild.md, step 5"
