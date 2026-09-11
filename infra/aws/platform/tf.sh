#!/usr/bin/env bash
# terraform for infra/aws/platform with its inputs supplied:
#
#   chart-versions.auto.tfvars   copied from infra/local (the SAME versions kind runs)
#   charts/<name>-<version>.tgz  pulled ONCE by helm into a local cache (Day 15 D4: a plan
#                                must not depend on GitHub answering eight times)
#   backend.hcl                  written by scripts/151-aws-state.sh (bucket + region)
#   AWS_PROFILE / region         from scripts/lib.sh — the aws-lab context is exec-auth,
#                                so terraform's kubectl calls need the SSO profile
#
#   ./infra/aws/platform/tf.sh plan
#   ./infra/aws/platform/tf.sh apply
#   ./infra/aws/platform/tf.sh plan -detailed-exitcode     # 0 clean, 1 error, 2 DRIFT
#   ./infra/aws/platform/tf.sh destroy
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/../../.." && pwd)"
cd "$HERE"
# shellcheck disable=SC1091
source "$LAB/scripts/lib.sh" >/dev/null 2>&1 || true     # AWS_PROFILE, AWS_REGION, say/ok/die
export TF_VAR_region="${AWS_REGION:-us-east-2}"
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"; mkdir -p "$TF_PLUGIN_CACHE_DIR"

[[ -f backend.hcl ]] || { echo "tf.sh: no infra/aws/platform/backend.hcl — ./scripts/151-aws-state.sh writes it" >&2; exit 1; }
[[ -f "$LAB/infra/local/chart-versions.auto.tfvars" ]] || { echo "tf.sh: no infra/local/chart-versions.auto.tfvars (Day 13's 130 writes it)" >&2; exit 1; }
cp "$LAB/infra/local/chart-versions.auto.tfvars" chart-versions.auto.tfvars

# ---- chart cache -------------------------------------------------------------------
# release -> "repo-url chart-name"; versions from the tfvars. Pull only what is missing.
declare -A REPO=(
  [kps]="https://prometheus-community.github.io/helm-charts kube-prometheus-stack"
  [pushgateway]="https://prometheus-community.github.io/helm-charts prometheus-pushgateway"
  [tempo]="https://grafana.github.io/helm-charts tempo"
  [otel]="https://open-telemetry.github.io/opentelemetry-helm-charts opentelemetry-collector"
  [fluent-bit]="https://fluent.github.io/helm-charts fluent-bit"
)
mkdir -p charts
for rel in "${!REPO[@]}"; do
  ver=$(grep -E "^\s*\"?${rel}\"?\s*=" chart-versions.auto.tfvars | grep -oE '"[0-9][^"]*"' | tail -1 | tr -d '"')
  [[ -n "$ver" ]] || { echo "tf.sh: no version for '$rel' in chart-versions.auto.tfvars" >&2; exit 1; }
  read -r url chart <<<"${REPO[$rel]}"
  f="charts/${chart}-${ver}.tgz"
  if [[ ! -f "$f" ]]; then
    echo "  pulling $chart $ver -> $f"
    helm pull --repo "$url" "$chart" --version "$ver" -d charts >/dev/null || { echo "tf.sh: helm pull $chart $ver failed (network?) — retry; the cache keeps what it has" >&2; exit 1; }
  fi
done

if [[ "${1:-}" == "init" ]]; then shift; exec terraform init -input=false -backend-config=backend.hcl "$@"; fi
[[ -d .terraform ]] || terraform init -input=false -backend-config=backend.hcl >/dev/null
exec terraform "$@"
