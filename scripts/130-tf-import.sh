#!/usr/bin/env bash
# Day 13, Step 3 — bring the running platform layer under Terraform WITHOUT recreating it.
#
# 1. pin every chart to the version that is actually installed (helm list -> tfvars, committed)
# 2. terraform init
# 3. import the four namespaces and five releases (skips anything already in state)
# 4. terraform plan -detailed-exitcode: 0 = the code provably describes reality
#
# Import-then-reconcile is what joining any company with existing infrastructure feels
# like. A plan you do not understand is a plan you cannot trust — the script prints the
# plan and, for the one diff that is expected after import, says why.
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"

step "Preconditions"
have terraform || die "terraform not installed — ./scripts/01-install-tools.sh"
TFV=$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1 | awk '{print $2}' | tr -d v)
ok "terraform $TFV"
python3 - "$TFV" <<'PY' || die "terraform >= 1.9 required (helm provider 3.x needs it)"
import sys; v=tuple(int(x) for x in sys.argv[1].split(".")[:2]); sys.exit(0 if v >= (1,9) else 1)
PY
[[ -f k8s/fluent-bit-values.yaml ]] || die "k8s/fluent-bit-values.yaml missing — the Fluent Bit release needs the HEC token from it (22-fluent-bit.sh)"
docker ps --format '{{.Names}}' | grep -qx splunk || die "splunk container not running (docker start splunk) — Terraform renders its IP into the Fluent Bit values"
ok "rendered Fluent Bit values present, Splunk at $(splunk_ip)"

step "Pinning chart versions to what is installed (helm list -A)"
helm list -A -o json --kube-context "$KUBE_CONTEXT" | python3 - <<'PY' > infra/local/chart-versions.auto.tfvars
import json, sys
rel = {r["name"]: r for r in json.load(sys.stdin)}
want = ["kps", "pushgateway", "tempo", "otel", "fluent-bit"]
missing = [n for n in want if n not in rel]
if missing:
    sys.stderr.write("releases not installed: %s\n" % ", ".join(missing)); sys.exit(1)
print("# Written by scripts/130-tf-import.sh from `helm list -A` on the day of import. COMMITTED:")
print("# these pins are the reason `terraform apply` never upgrades a chart by accident.")
print("chart_versions = {")
for n in want:
    chart = rel[n]["chart"]                      # e.g. kube-prometheus-stack-88.6.2
    ver = chart.rsplit("-", 1)[1]
    print('  "%s" = "%s"   # %s in %s, rev %s' % (n, ver, chart, rel[n]["namespace"], rel[n]["revision"]))
print("}")
PY
sed 's/^/  /' infra/local/chart-versions.auto.tfvars | grep -v '^  #'

step "terraform init (providers: hashicorp/kubernetes ~> 2.35, hashicorp/helm ~> 3.0)"
"$TF" init -input=false >/dev/null && ok "initialised — state at infra/local/terraform.tfstate (gitignored: it will hold the HEC token)"

step "Importing what already exists"
declare -A IMPORTS=(
  [kubernetes_namespace.payments]=payments
  [kubernetes_namespace.monitoring]=monitoring
  [kubernetes_namespace.tracing]=tracing
  [kubernetes_namespace.logging]=logging
  [helm_release.kps]=monitoring/kps
  [helm_release.pushgateway]=monitoring/pushgateway
  [helm_release.tempo]=tracing/tempo
  [helm_release.otel]=tracing/otel
  [helm_release.fluent_bit]=logging/fluent-bit
)
HAVE=$("$TF" state list 2>/dev/null || true)
for addr in kubernetes_namespace.payments kubernetes_namespace.monitoring kubernetes_namespace.tracing kubernetes_namespace.logging \
            helm_release.kps helm_release.pushgateway helm_release.tempo helm_release.otel helm_release.fluent_bit; do
  if grep -qx "$addr" <<<"$HAVE"; then ok "$addr already in state"; continue; fi
  if "$TF" import -input=false "$addr" "${IMPORTS[$addr]}" >/dev/null 2>infra/local/import.err; then
    ok "imported $addr  <-  ${IMPORTS[$addr]}"
  else
    warn "import failed for $addr:"; sed 's/^/    /' infra/local/import.err | head -8
    die "fix and re-run (idempotent: already-imported resources are skipped)"
  fi
done
rm -f infra/local/import.err

step "The moment of truth: terraform plan"
set +e
"$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1; RC=$?
set -e
case "$RC" in
  0) ok "PLAN CLEAN — the code provably describes reality. Nothing to apply."
     grep -E 'No changes' infra/local/plan.txt | head -1 | sed 's/^/  /' ;;
  2) warn "plan is NOT clean — read it before you trust it:"
     grep -E '^\s*[#~+-]|Plan:' infra/local/plan.txt | grep -vE '^\s*#\s*\(' | head -40 | sed 's/^/  /'
     echo
     say "  How to read the usual post-import diffs:"
     say "   ~ helm_release.* values  — expected once: the imported release stores its values as it"
     say "     received them; the file may differ only in ordering/whitespace/comments. Confirm with"
     say "       helm get values <name> -n <ns>     vs the k8s/*.yaml file"
     say "     If the EFFECTIVE values are identical, \`tf.sh apply\` does a no-op upgrade (revision +1)"
     say "     and the next plan is clean. If a key differs, reality wins: fix the file, not the cluster."
     say "   ~ repository / timeout / wait / depends — expected once: Helm does not store them in the"
     say "     release, so import leaves them empty; the first apply records them. Harmless."
     say "   ~ version                — must NOT appear. If it does, chart-versions.auto.tfvars is wrong."
     say "   - anything being DESTROYED or + CREATED — stop. An import is missing or an address is wrong."
     say "  Full plan: infra/local/plan.txt   Then: ./infra/local/tf.sh apply" ;;
  *) die "terraform plan failed (exit $RC): $(tail -20 infra/local/plan.txt)" ;;
esac

step "Commit the code (state stays out — .gitignore has it)"
say "  git add infra/local k8s/pushgateway-values.yaml k8s/activation.yaml .gitignore"
say "  git commit -m 'Day 13: platform layer under Terraform (imported, plan clean)'"
ok "Next: ./scripts/131-tf-change.sh  (one real change, the IaC way)"
