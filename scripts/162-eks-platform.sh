#!/usr/bin/env bash
# Day 16, Step 2 — the Day 13 platform code, applied onto EKS. This is the payoff of
# Day 13: the same four namespaces and five Helm releases, the same values files, with
# three differences (infra/aws/platform, each commented). No imports — the cluster is empty.
#
#   ./scripts/162-eks-platform.sh plan
#   ./scripts/162-eks-platform.sh apply     ~5 min; then proves it: releases, pods, targets, CloudWatch
#   ./scripts/162-eks-platform.sh status
#   ./scripts/162-eks-platform.sh destroy   helm releases + namespaces (167 runs this first)
export KUBE_CONTEXT=aws-lab
source "$(dirname "$0")/lib.sh"
require_aws; require_cluster
cd "$LAB_ROOT" || exit 1
TF="$AWS_PLATFORM/tf.sh"; chmod +x "$TF"
[[ -f "$AWS_PLATFORM/backend.hcl" ]] || die "no infra/aws/platform/backend.hcl — ./scripts/151-aws-state.sh wrote it on Day 15; re-run 151 (idempotent)"

case "${1:-}" in
  plan)
    step "1/4  The four namespaces (a targeted apply — a Secret needs somewhere to live)"
    # Terraform owns the namespaces (one owner, Day 13's rule), and kps needs
    # secret/grafana-admin to exist in `monitoring` BEFORE its release is planned with
    # existingSecret. So the namespaces go first, on their own, then the secret by kubectl
    # (Terraform never sees the password — Day 13 B10), then the real plan.
    "$TF" apply -input=false -no-color -auto-approve -target=kubernetes_namespace.monitoring -target=kubernetes_namespace.payments -target=kubernetes_namespace.tracing -target=kubernetes_namespace.logging > "$AWS_PLATFORM/apply.txt" 2>&1 \
      || { grep -E 'Error' -A4 "$AWS_PLATFORM/apply.txt" | head -12; die "namespaces apply failed"; }
    ok "namespaces: $(k get ns payments monitoring tracing logging --no-headers | awk '{print $1}' | tr '\n' ' ')"
    step "2/4  Grafana admin secret (kubectl, outside Terraform, like Day 13)"
    if k get secret grafana-admin -n "$MONITORING_NS" >/dev/null 2>&1; then ok "secret/grafana-admin exists"; else
      PW=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(24)))')
      k create secret generic grafana-admin -n "$MONITORING_NS" --from-literal=admin-user=admin --from-literal=admin-password="$PW" >/dev/null
      unset PW; ok "secret/grafana-admin created (not shown; ./scripts/06-grafana.sh prints it)"
    fi
    step "3/4  Prometheus Operator CRDs, from the cached chart (the plan is a server-side dry run — B11)"
    # With experiments.manifest = true every plan dry-runs the chart against the API, and
    # a dry run installs nothing — so on an EMPTY cluster the ServiceMonitor kind does not
    # exist yet and the plan fails "ensure CRDs are installed first". On kind the CRDs
    # were there since Day 1. Helm's own rule: CRDs in a chart's crds/ dir are installed
    # only if absent — so applying them first with kubectl (server-side: they are far
    # over the client-side annotation limit) is the documented path, and the release
    # that follows does not fight over them.
    "$TF" version >/dev/null     # tf.sh pulls the chart cache before running anything
    KPS_TGZ=$(ls "$AWS_PLATFORM"/charts/kube-prometheus-stack-*.tgz 2>/dev/null | head -1)
    [[ -n "$KPS_TGZ" ]] || die "no kube-prometheus-stack chart in infra/aws/platform/charts — tf.sh did not pull it"
    CRD_DIR=$(mktemp -d); trap 'rm -rf "$CRD_DIR"' EXIT
    # the chart's CRDs live in charts/crds/crds/crd-*.yaml (its templates/ dir also holds
    # *.yaml — Helm templates, not applyable — so the glob is exact)
    tar -xzf "$KPS_TGZ" -C "$CRD_DIR" --wildcards '*/charts/crds/crds/crd-*.yaml' 2>/dev/null || die "no charts/crds/crds/crd-*.yaml inside $KPS_TGZ"
    N_CRD=$(find "$CRD_DIR" -name 'crd-*.yaml' | wc -l)
    # create/replace, not apply: no last-applied annotation (client-side limit), no server-side
    # merge (the ~1 MB prometheuses CRD can exceed the API server's 60 s on a young control plane)
    for f in "$CRD_DIR"/*/charts/crds/crds/crd-*.yaml; do
      done_one=0
      for attempt in 1 2 3; do
        if k get -f "$f" >/dev/null 2>&1; then k replace -f "$f" >/dev/null 2>&1 && { done_one=1; break; }
        else k create -f "$f" >/dev/null 2>&1 && { done_one=1; break; }; fi
        sleep 5
      done
      (( done_one )) || die "CRD create/replace failed after 3 tries: $(basename "$f")"
    done
    ok "$N_CRD CRDs applied (server-side) — kubectl --context aws-lab get crd | grep monitoring.coreos.com"
    step "4/4  terraform plan — the five releases"
    "$TF" plan -input=false -no-color -out=platform.tfplan > "$AWS_PLATFORM/plan.txt" 2>&1 || { tail -20 "$AWS_PLATFORM/plan.txt"; die "plan failed"; }
    grep -E '^\s+# (kubernetes_namespace|kubernetes_storage_class_v1|helm_release)\.[a-z_0-9]+ (will be|must be)' "$AWS_PLATFORM/plan.txt" | sed 's/^\s*# /  /'
    grep -E '^Plan:' "$AWS_PLATFORM/plan.txt" | sed 's/^/  /'
    say "  Same versions as kind: $(grep -oE '"[a-z-]+" = "[0-9.]+"' "$AWS_PLATFORM/chart-versions.auto.tfvars" | tr '\n' ' ')"
    ok "Next: $0 apply   (applies exactly this plan)"
    ;;
  apply)
    [[ -f "$AWS_PLATFORM/platform.tfplan" ]] || die "no saved plan — $0 plan first"
    k get secret grafana-admin -n "$MONITORING_NS" >/dev/null 2>&1 || die "secret/grafana-admin missing — $0 plan creates it"
    step "terraform apply — the saved plan (kps ~3 min, the rest ~1 each)"
    T0=$(date +%s)
    "$TF" apply -input=false -no-color platform.tfplan > "$AWS_PLATFORM/apply.txt" 2>&1 \
      || { grep -E '^\s*(│ )?Error' -A6 "$AWS_PLATFORM/apply.txt" | head -24; die "apply failed — infra/aws/platform/apply.txt (a failed release is usually Pending pods: kubectl --context aws-lab get pods -A | grep -v Running; then $0 plan && $0 apply — it converges)"; }
    rm -f "$AWS_PLATFORM/platform.tfplan"
    grep -E '^Apply complete' "$AWS_PLATFORM/apply.txt" | sed 's/^/  /'
    ok "applied in $(( ($(date +%s) - T0) / 60 )) min — compare with week 1's command-by-command install"
    date -u +%FT%TZ > "$CHECKPOINTS/day16-platform-applied.txt"
    "$0" status
    ;;
  status)
    step "Releases (helm, context aws-lab) vs kind"
    helm --kube-context aws-lab list -A -o json 2>/dev/null | python3 -c '
import json,sys
for r in sorted(json.load(sys.stdin), key=lambda r:r["name"]): print("  %-12s %-11s %-36s %s" % (r["name"], r["namespace"], r["chart"], r["status"]))'
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx "kind-$CLUSTER_NAME" && kubectl --context "kind-$CLUSTER_NAME" get nodes >/dev/null 2>&1; then
      A=$(helm --kube-context aws-lab list -A -o json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted(r["chart"] for r in json.load(sys.stdin))))')
      K=$(helm --kube-context "kind-$CLUSTER_NAME" list -A -o json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted(r["chart"] for r in json.load(sys.stdin))))')
      [[ "$A" == "$K" ]] && ok "identical chart versions on both clusters" || warn "chart versions differ — kind: $K / eks: $A"
    fi
    step "Pods not Running"
    NR=$(k get pods -A --no-headers 2>/dev/null | awk '$4!="Running" && $4!="Completed"' || true)
    [[ -z "$NR" ]] && ok "every pod Running or Completed ($(k get pods -A --no-headers | wc -l) pods on $(k get nodes --no-headers | wc -l) nodes)" || { printf '%s\n' "$NR" | sed 's/^/  /'; warn "Pending = 'Insufficient cpu/memory' or 'Too many pods' → 160 status; ImagePull → 153 --verify" ; }
    step "Prometheus: targets down (expect none — the control-plane scrapes are off, kps-values-eks.yaml)"
    D=$(promql 'count by (job) (up == 0)' | python3 -c 'import json,sys
d=json.load(sys.stdin).get("data",{}).get("result",[])
print("\n".join("  %s x%s" % (r["metric"].get("job","?"), r["value"][1]) for r in d))' 2>/dev/null || true)
    [[ -z "$D" ]] && ok "no target down" || { printf '%s\n' "$D"; warn "a job at 0 right after apply is usually still starting; re-run status in a minute"; }
    step "CloudWatch: Fluent Bit's log group (auto_create_group — appears with the first payments log line, i.e. after 163)"
    LG=$(aws logs describe-log-groups --log-group-name-prefix /bhn-sim/containers --query 'logGroups[0].[logGroupName,retentionInDays,storedBytes]' --output text 2>/dev/null || true)
    [[ -n "$LG" && "$LG" != None ]] && ok "log group: $LG" || say "  not yet — nothing in payments has logged (or Pod Identity is not working: kubectl --context aws-lab -n logging logs ds/fluent-bit | grep -i -E 'credential|denied|error' )"
    ok "Next: ./scripts/163-eks-deploy.sh"
    ;;
  destroy)
    step "terraform destroy — infra/aws/platform (five releases, four namespaces; the namespaces take the services and the PVC with them)"
    read -rp "  Destroy the platform on EKS? [type yes] " a; [[ "$a" == yes ]] || die "not destroying"
    T0=$(date +%s)
    "$TF" destroy -input=false -no-color -auto-approve > "$AWS_PLATFORM/apply.txt" 2>&1 \
      || { grep -E '^\s*(│ )?Error' -A6 "$AWS_PLATFORM/apply.txt" | head -20; die "destroy failed — infra/aws/platform/apply.txt (a namespace stuck Terminating: kubectl --context aws-lab get ns; usually a finalizer on a PVC or a LoadBalancer Service)"; }
    grep -E '^Destroy complete' "$AWS_PLATFORM/apply.txt" | sed 's/^/  /'
    ok "destroyed in $(( ($(date +%s) - T0) / 60 )) min"
    # the EBS volume behind incident-bot's PVC: gone with the PVC (reclaimPolicy Delete) — prove it
    V=$(aws ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/$EKS_CLUSTER,Values=owned" --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
    [[ "$V" == 0 ]] && ok "no EBS volumes left from the cluster" || warn "$V EBS volume(s) tagged for the cluster still exist — 155 will show them; delete in the console if they persist"
    date -u +%FT%TZ > "$CHECKPOINTS/day16-platform-destroyed.txt"
    ;;
  *) die "usage: $0 plan|apply|status|destroy" ;;
esac
