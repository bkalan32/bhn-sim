#!/usr/bin/env bash
# Day 1, Step 3 (translated) — the Ubuntu equivalent of:
#   brew install kubectl kind helm terraform python@3.12 git
# Six upstream sources instead of one Homebrew line. Idempotent: safe to re-run.
#
# Docker is NOT installed here. Docker Desktop lives on the Windows side.

source "$(dirname "$0")/lib.sh"

KIND_VERSION="v0.33.0"      # verified latest 2026-09-01
K8S_APT_MINOR="v1.34"       # pkgs.k8s.io is versioned per minor release

step "Refreshing apt and installing base packages"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common git
ok "base packages + git"

# ---------------------------------------------------------------- kubectl ---
step "kubectl (apt repo pkgs.k8s.io ${K8S_APT_MINOR})"
if ! have kubectl; then
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/Release.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_APT_MINOR}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq kubectl
fi
ok "kubectl $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"

# ------------------------------------------------------------------- kind ---
step "kind ${KIND_VERSION} (binary — kind is not in apt)"
if ! have kind || [[ "$(kind --version | awk '{print "v"$3}')" != "$KIND_VERSION" ]]; then
  ARCH=$(dpkg --print-architecture)   # amd64 / arm64
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x /tmp/kind
  sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
fi
ok "$(kind --version)"

# ------------------------------------------------------------------- helm ---
step "helm (official install script)"
if ! have helm; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash >/dev/null
fi
ok "helm $(helm version --template '{{.Version}}')"

# -------------------------------------------------------------- terraform ---
step "terraform (HashiCorp apt repo)"
if ! have terraform; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq terraform
fi
ok "$(terraform --version | head -1)"

# ----------------------------------------------------------------- python ---
step "python 3.12"
PYMINOR="$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo 0)"
if [[ "$PYMINOR" -ge 12 ]]; then
  ok "system python3 is $(python3 --version | awk '{print $2}') — 3.12+, nothing to do"
  sudo apt-get install -y -qq python3-pip python3-venv
else
  warn "system python3 is 3.${PYMINOR}; adding deadsnakes PPA for 3.12"
  sudo add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq python3.12 python3.12-venv python3.12-dev
  ok "$(python3.12 --version) installed alongside system python3"
fi

step "Done"
dim "Docker was intentionally skipped — it is a Windows-side install. See DAY1.md Step 2."
ok "Next: scripts/02-verify.sh"
