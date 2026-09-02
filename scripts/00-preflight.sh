#!/usr/bin/env bash
# Day 1, Step 0 — check the machine can actually host the lab before installing anything.
# Nothing here changes your system. Read-only.

source "$(dirname "$0")/lib.sh"

FAILED=0
note() { warn "$*"; FAILED=1; }

step "Preflight checks"
require_wsl

# --- distro -----------------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  say "Distro: ${PRETTY_NAME:-unknown}"
  if [[ "${ID:-}" == "ubuntu" ]]; then
    case "${VERSION_ID:-}" in
      24.*|25.*|26.*) ok "Ubuntu $VERSION_ID ships Python 3.12+ natively — no deadsnakes PPA needed." ;;
      22.*) warn "Ubuntu 22.04 ships Python 3.10. 01-install-tools.sh will add the deadsnakes PPA for 3.12." ;;
      *)    warn "Untested Ubuntu release ${VERSION_ID:-?}. Should be fine; watch the Python step." ;;
    esac
  else
    warn "Not Ubuntu. The apt sources in 01-install-tools.sh assume Debian/Ubuntu."
  fi
fi

# --- memory -----------------------------------------------------------------
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_GB=$(( MEM_KB / 1024 / 1024 ))
say "Memory visible to this WSL distro: ${MEM_GB} GB"
if (( MEM_GB < 6 )); then
  note "Under 6 GB. The kind cluster plus kube-prometheus-stack will not fit.
       Fix on the WINDOWS side: create C:\\Users\\<you>\\.wslconfig containing
         [wsl2]
         memory=10GB
         processors=4
         swap=2GB
       then run 'wsl --shutdown' in PowerShell and reopen Ubuntu.
       (Docker Desktop's WSL2 backend has no memory slider — see CORRECTIONS-DAY1.md P2.)"
elif (( MEM_GB < 9 )); then
  warn "${MEM_GB} GB will work but is tight once Jenkins and Splunk arrive. 10 GB is the comfortable number."
else
  ok "Memory is comfortable."
fi

# --- cpu --------------------------------------------------------------------
CPUS=$(nproc)
say "CPUs visible: $CPUS"
(( CPUS >= 2 )) || note "Fewer than 2 CPUs. Raise 'processors' in .wslconfig."

# --- disk -------------------------------------------------------------------
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
say "Free space on / : ${DISK_GB} GB"
if (( DISK_GB < 25 )); then
  note "Under 25 GB free. kind images + monitoring + Jenkins + (Day 3) Splunk need ~40 GB.
       Note WSL2's virtual disk grows but never shrinks by itself."
elif (( DISK_GB < 40 )); then
  warn "${DISK_GB} GB is enough for Day 1 but will get tight by Day 3 (Splunk)."
else
  ok "Disk is comfortable."
fi

# --- docker -----------------------------------------------------------------
if have docker; then
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable: $(docker --version)"
  else
    note "docker CLI present but daemon unreachable.
       Start Docker Desktop on Windows, then Settings > Resources > WSL Integration,
       toggle ON this distro, and Apply & Restart."
  fi
else
  note "docker CLI not found in this distro.
       Install Docker Desktop on WINDOWS (winget install -e --id Docker.DockerDesktop),
       then enable WSL Integration for this distro. Do NOT apt-install docker inside Ubuntu."
fi

# --- network ----------------------------------------------------------------
if curl -fsS --max-time 8 https://kind.sigs.k8s.io/ >/dev/null 2>&1; then
  ok "Outbound HTTPS works."
else
  note "Cannot reach kind.sigs.k8s.io. Every install step needs the network."
fi

# --- port conflicts ---------------------------------------------------------
step "Ports this lab wants"
for p in 3000 8080 8081; do
  if (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":$p ") ; then
    warn "Port $p is already in use inside WSL. Day 1 wants 3000 (Grafana), 8080 (smoke test), 8081 (Jenkins)."
  else
    ok "Port $p free"
  fi
done
dim "Note: a Windows program holding one of these ports will not show up here."

step "Result"
if (( FAILED )); then
  die "Preflight found blocking problems. Fix the 'warn' lines above, then re-run."
fi
ok "Preflight passed. Next: scripts/01-install-tools.sh"
