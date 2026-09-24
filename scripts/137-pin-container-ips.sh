#!/usr/bin/env bash
# Give the two containers the cluster reaches BY IP — Splunk and Jenkins — fixed addresses on
# the kind network, in place (no new container: Splunk's data and trial, Jenkins's jobs stay).
#
#   ./scripts/137-pin-container-ips.sh           pin both (stops/starts only a container that needs it)
#   ./scripts/137-pin-container-ips.sh --check   are they pinned, and on their pinned address?
#
# Why (CORRECTIONS-REBUILD B10): kind's CoreDNS cannot resolve Docker container names, so Fluent
# Bit, the incident bot and Mission Control hold Splunk's and Jenkins's container IPs. Docker gives
# addresses in START order; after the 23 Sep power cut the three containers came back in a
# different order (jenkins .2, node .3, splunk .4) and every one of those addresses was wrong at
# once — logs stopped reaching Splunk and nobody was told for five hours. A fixed address makes
# the order irrelevant. 21-splunk-up.sh and 50-jenkins-rebuild.sh create them pinned from now on.
source "$(dirname "$0")/lib.sh"
require_docker
SPIN=$(kind_fixed_ip "$SPLUNK_IP_SUFFIX") || die "the kind network is not a /16 (docker network inspect kind)"
JPIN=$(kind_fixed_ip "$JENKINS_IP_SUFFIX") || die "the kind network is not a /16"

state() {  # name -> "<pinned-ipam-address> <current-address>"
  timeout 15 docker inspect -f '{{with .NetworkSettings.Networks.kind}}{{with .IPAMConfig}}{{.IPv4Address}}{{end}} {{.IPAddress}}{{end}}' "$1" 2>/dev/null || true
}

check() {
  local rc=0 name want st
  for pair in "$SPLUNK_CONTAINER:$SPIN" "jenkins:$JPIN"; do
    name=${pair%%:*}; want=${pair#*:}; st=$(state "$name")
    if [[ "$st" == "$want $want" ]]; then ok "$name pinned at $want"
    elif [[ "$st" == "$want "* ]]; then warn "$name pinned to $want but not running (current: '${st#* }')"; rc=1
    else warn "$name NOT pinned (ipam: '${st%% *}', current: '${st#* }') — $0"; rc=1; fi
  done
  return $rc
}

pin() {  # name address
  local name=$1 want=$2 st running
  st=$(state "$name")
  [[ -n "$st" ]] || { warn "$name: no such container on the kind network — skipped"; return; }
  if [[ "$st" == "$want $want" ]]; then ok "$name already pinned at $want"; return; fi
  running=$(timeout 15 docker inspect -f '{{.State.Running}}' "$name")
  say "  $name: ${st#* } -> $want"
  [[ "$running" == true ]] && { timeout 90 docker stop "$name" >/dev/null || die "docker stop $name timed out"; }
  timeout 30 docker network disconnect kind "$name" || die "disconnect $name failed"
  timeout 30 docker network connect --ip "$want" kind "$name" || die "connect --ip $want failed — the old address is gone; run: docker network connect kind $name"
  [[ "$running" == true ]] && { timeout 90 docker start "$name" >/dev/null || die "docker start $name failed"; }
  ok "$name pinned at $want"
}

if [[ "${1:-}" == "--check" ]]; then step "Fixed addresses on the kind network"; check; exit $?; fi

step "Pinning Splunk ($SPIN) and Jenkins ($JPIN)"
pin "$SPLUNK_CONTAINER" "$SPIN"
pin jenkins "$JPIN"
step "Check"; check || exit 1

step "Now the three things that hold those addresses"
say "  ./infra/local/tf.sh plan / apply    Fluent Bit's Splunk host (tf.sh reads it from Docker)"
say "  ./scripts/100-enrich-config.sh      the bot's SPLUNK_URL (and a fresh Grafana Viewer token)"
say "  ./scripts/210-mc-config.sh          Mission Control's JENKINS_URL"
dim "  Splunk takes 2-4 minutes to answer after a start: curl -sk https://localhost:8088/services/collector/health  (HTTPS: the image turns HEC SSL back on at every start — B11)"
