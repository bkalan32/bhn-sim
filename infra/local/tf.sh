#!/usr/bin/env bash
# Run terraform for infra/local with the three inputs that live OUTSIDE git supplied:
#
#   TF_VAR_splunk_ip         from `docker inspect splunk`   (moves on every Docker restart)
#   TF_VAR_splunk_hec_token  from the rendered, gitignored k8s/fluent-bit-values.yaml
#   TF_VAR_splunk_hec_tls    from the same file (On/Off)
#   state path               $TF_STATE_PATH, default infra/local/terraform.tfstate;
#                            the Jenkins drift job points it at /repo/infra/local/… so the
#                            clone it plans from reads the SAME state as your shell
#
#   ./infra/local/tf.sh plan
#   ./infra/local/tf.sh apply
#   ./infra/local/tf.sh plan -detailed-exitcode     # 0 clean, 1 error, 2 DRIFT
#   ./infra/local/tf.sh import helm_release.kps monitoring/kps
#
# Works from your WSL shell and inside the Jenkins container (docker CLI + /repo mount).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

VALUES="$LAB/k8s/fluent-bit-values.yaml"
[[ -f "$VALUES" ]] || VALUES=/repo/k8s/fluent-bit-values.yaml     # Jenkins: the clone has no rendered file; the bind mount does
if [[ -z "${TF_VAR_splunk_hec_token:-}" ]]; then
  [[ -f "$VALUES" ]] || { echo "tf.sh: no rendered k8s/fluent-bit-values.yaml (Day 3's 22-fluent-bit.sh) and no TF_VAR_splunk_hec_token" >&2; exit 1; }
  TF_VAR_splunk_hec_token="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$VALUES" | head -1 || true)"
  [[ -n "$TF_VAR_splunk_hec_token" ]] || { echo "tf.sh: no HEC token found in $VALUES" >&2; exit 1; }
  export TF_VAR_splunk_hec_token
fi
if [[ -z "${TF_VAR_splunk_hec_tls:-}" && -f "$VALUES" ]]; then
  TF_VAR_splunk_hec_tls="$(grep -E '^\s*TLS\s+(On|Off)' "$VALUES" | awk '{print $2}' | head -1 || true)"
  export TF_VAR_splunk_hec_tls="${TF_VAR_splunk_hec_tls:-On}"
fi
if [[ -z "${TF_VAR_splunk_ip:-}" ]]; then
  TF_VAR_splunk_ip="$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' splunk 2>/dev/null || true)"
  [[ -n "$TF_VAR_splunk_ip" ]] || { echo "tf.sh: splunk container not running (docker start splunk) and no TF_VAR_splunk_ip" >&2; exit 1; }
  export TF_VAR_splunk_ip
fi

STATE="${TF_STATE_PATH:-$HERE/terraform.tfstate}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-}"
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"; mkdir -p "$TF_PLUGIN_CACHE_DIR"

if [[ "${1:-}" == "init" ]]; then shift; exec terraform init -backend-config="path=$STATE" "$@"; fi
if [[ ! -d .terraform ]] || ! grep -q "\"path\": \"$STATE\"" .terraform/terraform.tfstate 2>/dev/null; then
  terraform init -input=false -reconfigure -backend-config="path=$STATE" >/dev/null
fi
exec terraform "$@"
