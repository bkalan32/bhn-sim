#!/usr/bin/env bash
# Shared helpers for the bhn-sim Day 1 scripts.

set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINTS="$LAB_ROOT/checkpoints"
CLUSTER_NAME="bhn-sim"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"   # kind prefixes contexts with "kind-" (see CORRECTIONS-DAY1.md B1)
# shellcheck disable=SC2034  # consumed by the scripts that source this file
MONITORING_NS="monitoring"
# shellcheck disable=SC2034
HELM_RELEASE="kps"

mkdir -p "$CHECKPOINTS"

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok  %s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s warn %s %s\n' "$C_WARN" "$C_OFF" "$*"; }
die()  { printf '%s FAIL %s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
step() { printf '\n%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

have() { command -v "$1" >/dev/null 2>&1; }

require_wsl() {
  if ! grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    warn "This does not look like WSL2. The scripts still work on plain Linux,"
    warn "but the Windows-specific advice in DAY1.md will not apply."
  fi
}

require_docker() {
  have docker || die "docker CLI not found. Install Docker Desktop on Windows, then enable
       Settings > Resources > WSL Integration for this distro. See DAY1.md Step 2."
  if ! docker info >/dev/null 2>&1; then
    die "Docker CLI is installed but the daemon is unreachable.
       Start Docker Desktop on Windows and make sure WSL Integration is ON for this distro."
  fi
}

require_cluster() {
  have kubectl || die "kubectl not found. Run scripts/01-install-tools.sh first."
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" \
    || die "Context '$KUBE_CONTEXT' not found. Run scripts/03-cluster-up.sh first."
  kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cluster '$CLUSTER_NAME' is not responding. Is Docker Desktop running?"
}

# Every kubectl call in these scripts is context-pinned, so an unrelated
# kubeconfig context can never send lab commands at the wrong cluster.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# ---------------------------------------------------------------- Day 2 -----
# shellcheck disable=SC2034  # consumed by the scripts that source this file
PAYMENTS_NS="payments"
# shellcheck disable=SC2034
APP_IMAGE="activation"
# shellcheck disable=SC2034
APP_TAG="0.1"

# Service names in kube-prometheus-stack depend on the Helm release name in a way
# that is genuinely hard to predict (the chart builds them with a 26-character
# truncation), and the labels it applies have changed between chart versions.
# So: try several strategies, never guess, and never fail hard -- a bare `die`
# after a failed command substitution under `set -e` exits with NO message at all.
_svc_by_label() {
  kubectl --context "$KUBE_CONTEXT" get svc -n "$MONITORING_NS" -l "$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
_svc_by_name() {
  kubectl --context "$KUBE_CONTEXT" get svc -n "$MONITORING_NS" \
    -o name 2>/dev/null | sed 's|^service/||' | grep -E "$1" | grep -v -- '-operated$' | head -1 || true
}

prom_svc() {
  local s
  for sel in "app.kubernetes.io/name=prometheus" \
             "app=kube-prometheus-stack-prometheus" \
             "operated-prometheus=true"; do
    s="$(_svc_by_label "$sel")"; [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  done
  s="$(_svc_by_name '(^|-)prometheus$')"; [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  return 1
}

alertmanager_svc() {
  local s
  for sel in "app.kubernetes.io/name=alertmanager" \
             "app=kube-prometheus-stack-alertmanager" \
             "operated-alertmanager=true"; do
    s="$(_svc_by_label "$sel")"; [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  done
  s="$(_svc_by_name '(^|-)alertmanager$')"; [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  return 1
}

# Print every service in the monitoring namespace. Called when discovery fails, so
# you can see what IS there instead of staring at an empty prompt.
show_monitoring_svcs() {
  warn "Services in namespace '$MONITORING_NS':"
  kubectl --context "$KUBE_CONTEXT" get svc -n "$MONITORING_NS" 2>&1 | sed 's/^/    /'
}

# Run a PromQL query through a temporary port-forward and return raw JSON.
promql() {
  local q="$1" svc pf_pid out
  svc="$(prom_svc)"; [[ -n "$svc" ]] || { echo '{"error":"prometheus service not found"}'; return 1; }
  kubectl --context "$KUBE_CONTEXT" port-forward "svc/$svc" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 &
  pf_pid=$!
  sleep 3
  out=$(curl -fsS --get --data-urlencode "query=${q}" http://localhost:9090/api/v1/query 2>/dev/null || echo '{}')
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  printf '%s' "$out"
}

# ---------------------------------------------------------------- Day 3 -----
# shellcheck disable=SC2034
LOGGING_NS="logging"
# shellcheck disable=SC2034
SPLUNK_CONTAINER="splunk"
# shellcheck disable=SC2034
SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-Changeme123!}"

# The Splunk container's IP on the kind Docker network. Container IPs are reassigned
# on restart, so never hardcode this into a values file by hand — render it.
splunk_ip() {
  docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$SPLUNK_CONTAINER" 2>/dev/null || true
}

# ---------------------------------------------------------------- Day 4 -----
# shellcheck disable=SC2034
TRACING_NS="tracing"

tempo_svc() {
  kubectl --context "$KUBE_CONTEXT" get svc -n "$TRACING_NS" -o name 2>/dev/null \
    | sed 's|^service/||' | grep -E '^tempo$' | head -1 || true
}

# Build a service image the same way every time: venv, deps, OpenTelemetry bootstrap,
# lock file, docker build, kind load. Used by activation and egift (and Day 5's
# settlement job), so the recipe lives in exactly one place.
build_service() {
  local name="$1" tag="$2" dir="$LAB_ROOT/services/$1"
  [[ -d "$dir" ]] || die "services/$name not found"
  ( cd "$dir" || exit 1
    [[ -d .venv ]] || python3 -m venv .venv || die "python3-venv missing: sudo apt-get install -y python3-venv"
    # shellcheck disable=SC1091
    source .venv/bin/activate
    pip install --quiet --upgrade pip
    pip install --quiet -r requirements.txt
    # Detects fastapi/requests/etc. in the venv and installs the matching
    # opentelemetry-instrumentation-* packages, version-matched to the core.
    if grep -q opentelemetry-distro requirements.txt; then
      opentelemetry-bootstrap -a install --quiet 2>/dev/null || opentelemetry-bootstrap -a install >/dev/null
    fi
    pip freeze > requirements.lock.txt
    ok "$name: $(grep -c . requirements.lock.txt) packages pinned into requirements.lock.txt"
    docker build --build-arg "APP_VERSION=${tag}" -t "${name}:${tag}" . \
      || die "docker build failed for ${name}:${tag}"
    kind load docker-image "${name}:${tag}" --name "$CLUSTER_NAME"
    ok "${name}:${tag} built and loaded into kind"
  )
}
