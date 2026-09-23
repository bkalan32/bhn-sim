#!/usr/bin/env bash
# Day 21 (CORRECTIONS-DAY21 B4) — give the single-node control plane room to be slow.
#
# kube-controller-manager and kube-scheduler each hold a leader LEASE they must renew every
# few seconds (defaults: lease 15 s, renew deadline 10 s, retry 2 s). On a node that is also
# running Splunk, Jenkins builds and `kind load`, a CPU storm delays a renewal past 10 s, the
# component gives up leadership and EXITS — restarted by the kubelet, counted by
# PlatformPodRestarting. On 23 Sep: controller-manager 8 restarts, scheduler 5, in step with
# every build and image cleanup. Leader election exists to fail over between replicas; this
# cluster has one of each, so there is nothing to fail over TO — a longer lease costs nothing.
#
#   ./scripts/136-control-plane-leases.sh           apply (idempotent; the kubelet restarts both once)
#   ./scripts/136-control-plane-leases.sh --check   show the current flags
#
# Edits the static pod manifests inside the kind node. Run after every 03-cluster-up.sh
# (docs/rebuild.md step 1) — a kubeadm config patch would be the code-first way, but its
# schema changed at v1beta4 and a wrong guess there breaks cluster creation outright.
source "$(dirname "$0")/lib.sh"
require_docker; require_cluster
NODE="${CLUSTER_NAME}-control-plane"
M=/etc/kubernetes/manifests
FLAGS='--leader-elect-lease-duration=60s --leader-elect-renew-deadline=40s --leader-elect-retry-period=10s'

show() { for c in kube-controller-manager kube-scheduler; do
  printf '  %-24s %s\n' "$c" "$(docker exec "$NODE" grep -oE -- '--leader-elect[a-z-]*=[^ ]+' "$M/$c.yaml" | tr '\n' ' ')"; done; }

step "Leader-election flags now"
show
[[ "${1:-}" == "--check" ]] && exit 0

for c in kube-controller-manager kube-scheduler; do
  if docker exec "$NODE" grep -q -- '--leader-elect-lease-duration' "$M/$c.yaml"; then
    ok "$c already tuned"; continue
  fi
  # insert the three flags right after `- --leader-elect=true`, same indentation
  docker exec "$NODE" sh -c "sed -i 's|^\(\s*\)- --leader-elect=true\$|&\n\1- --leader-elect-lease-duration=60s\n\1- --leader-elect-renew-deadline=40s\n\1- --leader-elect-retry-period=10s|' $M/$c.yaml"
  docker exec "$NODE" grep -q -- '--leader-elect-lease-duration=60s' "$M/$c.yaml" && ok "$c: $FLAGS" || die "$c: flags not inserted — look at $M/$c.yaml in the node"
done

step "The kubelet restarts both static pods (~30 s)"
sleep 20
for _ in $(seq 1 12); do
  n=$(k get pods -n kube-system --no-headers 2>/dev/null | grep -E 'kube-(controller-manager|scheduler)' | grep -c ' Running ' || true)
  (( n == 2 )) && break; sleep 5
done
k get pods -n kube-system --no-headers | grep -E 'kube-(controller-manager|scheduler)' | sed 's/^/  /'
show
ok "done — restarts counted by PlatformPodRestarting should stop climbing with every build"
