#!/usr/bin/env bash
# Shared helpers for the bhn-sim Day 1 scripts.

set -Eeuo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINTS="$LAB_ROOT/checkpoints"
CLUSTER_NAME="bhn-sim"
# kind prefixes contexts with "kind-" (CORRECTIONS-DAY1.md B1). Day 16: the SAME scripts run
# against EKS with one variable — `KUBE_CONTEXT=aws-lab ./scripts/06-grafana.sh` — because
# every kubectl call below is pinned to $KUBE_CONTEXT and the Python tools read the same
# env. Default stays kind, so nothing you ran for two weeks changes behaviour.
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-${CLUSTER_NAME}}"
export KUBE_CONTEXT
# Exactly one context is "the cloud": these scripts refuse anything that is not kind or aws-lab.
case "$KUBE_CONTEXT" in kind-*|aws-lab) ;; *) echo "lib.sh: KUBE_CONTEXT='$KUBE_CONTEXT' is neither the kind context nor aws-lab — refusing" >&2; exit 1 ;; esac
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
  if ! timeout 15 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    die "Docker CLI is installed but the daemon is unreachable.
       Start Docker Desktop on Windows and make sure WSL Integration is ON for this distro."
  fi
}

require_cluster() {
  have kubectl || die "kubectl not found. Run scripts/01-install-tools.sh first."
  if [[ "$KUBE_CONTEXT" == aws-lab ]]; then
    kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" \
      || die "Context 'aws-lab' not found. ./scripts/161-eks-kubeconfig.sh (after 160 apply)."
    kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1 \
      || die "EKS cluster not answering on context aws-lab — aws sso login --profile ${AWS_PROFILE:-lab}? destroyed? (./scripts/160-eks.sh status)"
    return 0
  fi
  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$KUBE_CONTEXT" \
    || die "Context '$KUBE_CONTEXT' not found. Run scripts/03-cluster-up.sh first."
  kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1 \
    || die "Cluster '$CLUSTER_NAME' is not responding. Is Docker Desktop running?"
}
on_eks() { [[ "$KUBE_CONTEXT" == aws-lab ]]; }

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

# Run a PromQL instant query and return raw JSON. Day 12: through the API server's service
# proxy (like the bot and the copilot), not a temporary port-forward — the port-forward
# raced its own 3-second sleep and, after a WSL restart, the localhost relay itself.
promql() {
  local q="$1" svc enc
  svc="$(prom_svc)"; [[ -n "$svc" ]] || { echo '{"error":"prometheus service not found"}'; return 1; }
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$q")
  kubectl --context "$KUBE_CONTEXT" get --raw "/api/v1/namespaces/${MONITORING_NS}/services/${svc}:9090/proxy/api/v1/query?query=${enc}" 2>/dev/null || echo '{}'
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
# Day 13 (CORRECTIONS B10): Grafana's admin password lives in secret/grafana-admin, which
# 134-tf-deterministic.sh mints from the chart's own secret; before that day, in
# secret/kps-grafana. Try ours first, fall back to the chart's. Never echo it.
grafana_admin_password() {
  local p
  p=$(k get secret grafana-admin -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [[ -n "$p" ]] || p=$(k get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  printf '%s' "$p"
}

splunk_ip() {
  docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' "$SPLUNK_CONTAINER" 2>/dev/null || true
}

# Day 22 (CORRECTIONS-REBUILD B10): Splunk and Jenkins get FIXED addresses on the kind network.
# Docker hands out .2, .3, .4 in start order, so a restart that starts the containers in a
# different order moves every address — on 24 Sep that silently broke Fluent Bit -> Splunk,
# the bot's log collector and Mission Control's Jenkins URL at once. The pinned addresses sit
# at the top of the /16 (x.y.255.10 / .11), far from anything Docker allocates on its own.
kind_fixed_ip() {  # suffix  -> <first two octets of the kind subnet>.255.<suffix>
  local subnet
  subnet=$(timeout 15 docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
    | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.0\.0/16$' || true)
  [[ -n "$subnet" ]] || { echo ""; return 1; }
  printf '%s.255.%s' "${subnet%.0.0/16}" "$1"
}
SPLUNK_IP_SUFFIX=10
JENKINS_IP_SUFFIX=11

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

# ---------------------------------------------------------------- Day 8 -----
# The API server can proxy plain HTTP to any Service. No port-forward, no pinned pod,
# works wherever kubectl works. Used for the incident bot and for reading Alertmanager.
BOT_PROXY="/api/v1/namespaces/${PAYMENTS_NS}/services/incident-bot:8020/proxy"
bot_get()  { kubectl --context "$KUBE_CONTEXT" get --raw "${BOT_PROXY}$1" 2>/dev/null || true; }
alertmanager_get() {
  local svc; svc="$(alertmanager_svc || true)"; [[ -n "$svc" ]] || return 0
  kubectl --context "$KUBE_CONTEXT" get --raw "/api/v1/namespaces/${MONITORING_NS}/services/${svc}:9093/proxy$1" 2>/dev/null || true
}

# ---------------------------------------------------------------- Day 12 ----
REM_PROXY="/api/v1/namespaces/${PAYMENTS_NS}/services/remediator:8030/proxy"
rem_get() { kubectl --context "$KUBE_CONTEXT" get --raw "${REM_PROXY}$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- Day 15 ----
# AWS. One profile (SSO, short-lived credentials — 150-aws-guardrails.sh) and one region,
# everywhere. Change the region in ONE place (here and infra/aws/*/variables) — B1.
# shellcheck disable=SC2034
export AWS_PROFILE="${AWS_PROFILE:-lab}"
# shellcheck disable=SC2034
export AWS_REGION="${AWS_REGION:-us-east-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
AWS_ENV="$LAB_ROOT/infra/aws/env"
AWS_BACKEND_ROOT="$LAB_ROOT/infra/aws/backend"
# Day 16: two more roots, one state key each (CORRECTIONS-DAY16 D1)
# shellcheck disable=SC2034
AWS_EKS="$LAB_ROOT/infra/aws/eks"
# shellcheck disable=SC2034
AWS_PLATFORM="$LAB_ROOT/infra/aws/platform"
# shellcheck disable=SC2034
EKS_CLUSTER="bhn-sim"

require_aws() {
  have aws || die "aws CLI not installed — ./scripts/150-aws-guardrails.sh --install"
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "no AWS session for profile '$AWS_PROFILE' — aws sso login --profile $AWS_PROFILE   (or ./scripts/150-aws-guardrails.sh)"
}
aws_account() { aws sts get-caller-identity --query Account --output text 2>/dev/null; }
aws_registry() { printf '%s.dkr.ecr.%s.amazonaws.com' "$(aws_account)" "$AWS_REGION"; }
# terraform for a root under infra/aws, with the S3 backend config file if present
tf_aws() {  # root args...
  local root="$1"; shift
  if [[ -f "$root/backend.hcl" && ! -d "$root/.terraform" ]]; then
    terraform -chdir="$root" init -input=false -backend-config=backend.hcl >/dev/null
  fi
  terraform -chdir="$root" "$@"
}
