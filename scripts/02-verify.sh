#!/usr/bin/env bash
# Day 1, Step 3 checkpoint — "Save the output to a notes file. This is your first checkpoint."
# Writes checkpoints/day1-versions.txt and fails loudly if any of the seven tools is missing.

source "$(dirname "$0")/lib.sh"

OUT="$CHECKPOINTS/day1-versions.txt"
MISSING=0

step "Verifying the seven tools"
{
  echo "bhn-sim Day 1 checkpoint"
  echo "generated: $(date -Iseconds)"
  echo "host:      $(uname -srm)"
  echo "distro:    $( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  echo
} > "$OUT"

check() {
  local name="$1"; shift
  if have "$1"; then
    local v; v="$("$@" 2>&1 | head -3)"
    printf '%s:\n%s\n\n' "$name" "$v" >> "$OUT"
    ok "$name"
  else
    printf '%s: NOT INSTALLED\n\n' "$name" >> "$OUT"
    warn "$name is missing"
    MISSING=1
  fi
}

check docker    docker --version
check kubectl   kubectl version --client
check kind      kind --version
check helm      helm version
check terraform terraform --version
check python    python3 --version
check git       git --version

step "Docker daemon"
if have docker && docker info >/dev/null 2>&1; then
  ok "daemon reachable"
  echo "docker daemon: reachable" >> "$OUT"
else
  warn "docker CLI present but daemon unreachable — start Docker Desktop + enable WSL Integration"
  echo "docker daemon: UNREACHABLE" >> "$OUT"
  MISSING=1
fi

step "Checkpoint saved"
say "$OUT"
dim "$(sed -n '1,4p' "$OUT")"

(( MISSING == 0 )) || die "Some tools are missing. Re-run scripts/01-install-tools.sh."
ok "All seven tools answer --version. Next: scripts/03-cluster-up.sh"
