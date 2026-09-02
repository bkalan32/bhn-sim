#!/usr/bin/env bash
# Tear the lab down. Useful when you want to prove the runbook works by rebuilding
# from scratch — which is the actual test of a good runbook.

source "$(dirname "$0")/lib.sh"

read -rp "Delete the '${CLUSTER_NAME}' cluster and the Jenkins container? [y/N] " a
[[ "$a" == [yY] ]] || { say "Aborted."; exit 0; }

step "Deleting cluster"
kind delete cluster --name "$CLUSTER_NAME" || true

step "Removing Jenkins container"
docker rm -f jenkins 2>/dev/null || true
dim "The 'jenkins_home' volume is KEPT so you do not lose your job config."
dim "To wipe it too: docker volume rm jenkins_home"

ok "Torn down. Rebuild with 03-cluster-up.sh -> 05 -> 07."
