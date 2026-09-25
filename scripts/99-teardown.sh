#!/usr/bin/env bash
# Destroy the local lab — everything that runs, and everything it stored. The repo is the lab:
# a rebuild from it is the real test of the runbook (README: Day 1 -> 03, 05, 07, 21 ...).
#
#   ./scripts/249-export-record.sh     FIRST — keep what Mission Control and the bot remember
#   ./scripts/99-teardown.sh           then this; it asks before deleting anything
#
# What goes (in this order):
#   1. the port-forwards (220-mc-open.sh)
#   2. the kind cluster bhn-sim — every service, Prometheus/Grafana/Loki/Tempo, the incident bot,
#      Mission Control and their PVCs, every Kubernetes secret (AI key, HEC token, Grafana, NR, MC)
#   3. the Splunk and Jenkins containers and their data (jenkins_home, Splunk's volumes)
#   4. the local Terraform state for infra/local (it describes a cluster that no longer exists)
#   5. the local credentials: ~/.bhn-sim/mc-token and the gitignored checkpoints/*credentials*
#   6. with --images: the images the lab built (every service tag, jenkins-lab, kindest/node, splunk)
# What stays: the repo and git history; AWS is NOT touched (see the end).
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
IMAGES=0; [[ "${1:-}" == "--images" ]] && IMAGES=1

[[ -d records ]] || warn "no records/ — run ./scripts/249-export-record.sh first, or the audit log dies with the cluster"
say "This DELETES the '${CLUSTER_NAME}' cluster, the splunk and jenkins containers and their data,"
say "the local Terraform state and your local lab credentials.$( ((IMAGES)) && echo ' And the lab images.')"
read -rp "Type the cluster name to confirm: " a
[[ "$a" == "$CLUSTER_NAME" ]] || { say "Aborted — nothing deleted."; exit 0; }

step "1 · Port-forwards"
./scripts/220-mc-open.sh --stop >/dev/null 2>&1 || true
pkill -f "kubectl.*port-forward" 2>/dev/null || true
ok "stopped"

step "2 · The kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME" && ok "cluster $CLUSTER_NAME deleted (and its kube context)"
else ok "no cluster $CLUSTER_NAME"; fi

step "3 · Splunk and Jenkins, with their data"
for c in splunk jenkins; do
  if docker inspect "$c" >/dev/null 2>&1; then docker rm -fv "$c" >/dev/null && ok "$c removed (with its anonymous volumes)"
  else ok "no $c container"; fi
done
docker volume rm jenkins_home >/dev/null 2>&1 && ok "volume jenkins_home removed (the jobs are in ci/*.job.xml)" || ok "no jenkins_home volume"
docker network rm kind >/dev/null 2>&1 && ok "docker network kind removed" || true

step "4 · Local Terraform state (infra/local)"
rm -f infra/local/terraform.tfstate infra/local/terraform.tfstate.* infra/local/.terraform.tfstate.lock.info infra/local/*.txt
rm -rf infra/local/.terraform
ok "state removed — a rebuild starts from an empty state, as a new machine would"

step "5 · Local credentials"
rm -f "$HOME/.bhn-sim/mc-token" && ok "~/.bhn-sim/mc-token removed"
for f in checkpoints/day1-grafana-credentials.txt checkpoints/day1-jenkins-unlock.txt checkpoints/day3-splunk.txt \
         ci/kubeconfig-internal.yaml k8s/fluent-bit-values.yaml; do
  [[ -f "$f" ]] && rm -f "$f" && ok "$f removed (gitignored; it held a credential or a rendered secret)"
done

if (( IMAGES )); then
  step "6 · Images the lab built"
  REPOS="activation|egift|settlement|incident-bot|remediator|loadgen|mission-control|jenkins-lab|kindest/node|splunk/splunk"
  IDS=$(docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -E "^($REPOS):" | awk '{print $2}' | sort -u || true)
  [[ -n "$IDS" ]] && docker rmi -f $IDS >/dev/null 2>&1; ok "$(echo -n "$IDS" | grep -c . || true) image(s) removed"
  docker builder prune -af >/dev/null 2>&1 && ok "build cache pruned"
fi

step "Left to check by hand"
dim "  git status                          — records/ committed? nothing else pending?"
dim "  ./scripts/155-aws-verify-destroyed.sh   (after: aws sso login --profile ${AWS_PROFILE:-lab}) — nothing in AWS bills"
dim "  Revoke keys you no longer need: the Anthropic API key (console), the New Relic license key."
dim "  Windows, to give the disk back:  wsl --shutdown   then compact the WSL/Docker vhdx"
ok "Local lab destroyed. Rebuild from the repo: README -> 03-cluster-up.sh, 05, 07, ..."
