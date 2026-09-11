#!/usr/bin/env bash
# Day 16, Step 1b — reach the cluster, and prove the things the apply promised.
#
# Writes context `aws-lab` into ~/.kube/config as an EXEC entry: every kubectl call runs
# `aws eks get-token` with the SSO profile — a 15-minute token, nothing long-lived on disk.
# From now on two clusters share one kubeconfig. Every lab script pins its context
# (lib.sh: KUBE_CONTEXT, default kind); the PDF's `kubectl config use-context aws-lab`
# is exactly the habit that ends with `kubectl delete` on the wrong cluster, so the
# current-context is left ALONE and you say `--context aws-lab` (or KUBE_CONTEXT=aws-lab)
# every time. Check `kubectl config current-context` before anything destructive, forever.
source "$(dirname "$0")/lib.sh"
require_aws

step "kubeconfig: context aws-lab (exec auth via profile $AWS_PROFILE)"
# update-kubeconfig SWITCHES current-context to the new alias by default (B9's trap, built
# into the CLI). Remember what it was, write the context, put it back.
PREV=$(kubectl config current-context 2>/dev/null || echo "")
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" --profile "$AWS_PROFILE" --alias aws-lab >/dev/null \
  || die "update-kubeconfig failed — is the cluster ACTIVE? ./scripts/160-eks.sh status"
if [[ -n "$PREV" && "$PREV" != aws-lab ]]; then kubectl config use-context "$PREV" >/dev/null; fi
CUR=$(kubectl config current-context 2>/dev/null || echo none)
[[ "$CUR" == aws-lab ]] && warn "current-context is aws-lab (there was no previous context to restore) — bare kubectl now means the CLOUD cluster; say --context" \
  || ok "context aws-lab written; current-context restored to '$CUR' — bare kubectl still means kind"
grep -q "AWS_PROFILE" ~/.kube/config && ok "the exec entry carries AWS_PROFILE=$AWS_PROFILE (tokens minted from SSO, 15 min each)" || warn "kubeconfig exec entry has no AWS_PROFILE — kubectl will use the default profile"

step "Who am I, to the cluster? (the access entry from enable_cluster_creator_admin_permissions)"
kubectl --context aws-lab auth whoami 2>/dev/null | sed 's/^/  /' || warn "auth whoami not answering yet"
kubectl --context aws-lab auth can-i '*' '*' >/dev/null 2>&1 && ok "cluster-admin via the EKS access entry for your SSO role (not aws-auth ConfigMap)" || warn "not cluster-admin — aws eks list-access-entries --cluster-name $EKS_CLUSTER"

step "Nodes (expect 2 Ready, SPOT, two AZs)"
for _ in $(seq 1 30); do
  R=$(kubectl --context aws-lab get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  (( R >= 2 )) && break; sleep 10
done
kubectl --context aws-lab get nodes -o custom-columns='NODE:.metadata.name,STATUS:.status.conditions[-1].type,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type,AZ:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY:.metadata.labels.eks\.amazonaws\.com/capacityType,MAX-PODS:.status.allocatable.pods' | sed 's/^/  /'
(( R >= 2 )) && ok "$R nodes Ready" || die "only $R Ready after 5 min — kubectl --context aws-lab describe nodes | grep -A5 Conditions; usually the vpc-cni add-on (160 status)"
MP=$(kubectl --context aws-lab get nodes -o jsonpath='{.items[0].status.allocatable.pods}' 2>/dev/null || true); MP="${MP:-0}"
if (( MP >= 100 )); then ok "max-pods $MP per node — prefix delegation is on (17 without it; the platform needs ~30 across two nodes)"
else warn "max-pods is $MP — prefix delegation did not take (vpc-cni configuration) — Pending pods with 'Too many pods' will follow; 160 status / scale to 3"; fi

step "Add-ons"
for a in vpc-cni coredns kube-proxy eks-pod-identity-agent aws-ebs-csi-driver; do
  S=$(aws eks describe-addon --cluster-name "$EKS_CLUSTER" --addon-name "$a" --query 'addon.status' --output text 2>/dev/null || echo MISSING)
  [[ "$S" == ACTIVE ]] && ok "$a ACTIVE" || warn "$a: $S"
done
kubectl --context aws-lab get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class' 2>/dev/null | sed 's/^/  /'

step "Pod identity associations (how pods get AWS permissions — eks-notes #5)"
aws eks list-pod-identity-associations --cluster-name "$EKS_CLUSTER" --query 'associations[].[namespace,serviceAccount]' --output text 2>/dev/null | awk '{printf "  %s/%s\n",$1,$2}'

step "What is NOT here (eks-notes #4)"
KS=$(kubectl --context aws-lab get pods -n kube-system --no-headers 2>/dev/null | awk '{print $1}' | sed 's/-[a-z0-9]*-[a-z0-9]*$//;s/-[a-z0-9]*$//' | sort -u | tr '\n' ' ')
say "  kube-system runs: $KS"
say "  no kube-apiserver, no etcd, no scheduler, no controller-manager pods: AWS runs them. Their health is the EKS"
say "  console and CloudWatch (log group /aws/eks/$EKS_CLUSTER/cluster), not 'kubectl describe pod'."
ok "Next: ./scripts/162-eks-platform.sh plan"
