#!/usr/bin/env bash
# Run terraform for infra/local with the inputs that live OUTSIDE git supplied:
#
#   TF_VAR_splunk_ip         from `docker inspect splunk`   (pinned since B10: 137-pin-container-ips.sh)
#   TF_VAR_splunk_hec_tls    asked of Splunk's HEC (https or http answers?); the rendered file only as fallback
#   (the HEC token is NOT an input any more: Fluent Bit reads it from secret/splunk-hec — B9)
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

if [[ -z "${TF_VAR_splunk_ip:-}" ]]; then
  TF_VAR_splunk_ip="$(timeout 15 docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' splunk 2>/dev/null || true)"
  [[ -n "$TF_VAR_splunk_ip" ]] || { echo "tf.sh: no Splunk IP after 15 s — splunk not running (docker start splunk), or the Docker CLI is not answering (timeout 10 docker version); or set TF_VAR_splunk_ip" >&2; exit 1; }
  export TF_VAR_splunk_ip
fi

# HEC's scheme is ASKED of Splunk, not read from the file 22-fluent-bit.sh rendered on day 3
# (CORRECTIONS-REBUILD B11): the splunk/splunk image re-runs its setup on every container start
# and puts HEC back on HTTPS, so a remembered "Off" goes stale at the first restart. localhost
# works from WSL (published port); the container IP works from Jenkins (on the kind network).
hec_scheme() {
  local h
  for h in localhost "$TF_VAR_splunk_ip"; do
    [[ "$(curl -sk -m 4 -o /dev/null -w '%{http_code}' "https://$h:8088/services/collector/health" 2>/dev/null)" == 200 ]] && { echo On; return; }
    [[ "$(curl -s  -m 4 -o /dev/null -w '%{http_code}' "http://$h:8088/services/collector/health"  2>/dev/null)" == 200 ]] && { echo Off; return; }
  done
}
VALUES="$LAB/k8s/fluent-bit-values.yaml"
[[ -f "$VALUES" ]] || VALUES=/repo/k8s/fluent-bit-values.yaml     # Jenkins: the clone has no rendered file; the bind mount does
if [[ -z "${TF_VAR_splunk_hec_tls:-}" ]]; then
  TF_VAR_splunk_hec_tls="$(hec_scheme || true)"
  if [[ -z "$TF_VAR_splunk_hec_tls" && -f "$VALUES" ]]; then   # Splunk not answering: last known, and say so
    TF_VAR_splunk_hec_tls="$(grep -E '^\s*TLS\s+(On|Off)' "$VALUES" | awk '{print $2}' | head -1 || true)"
    echo "tf.sh: HEC did not answer on http or https — using the rendered file's TLS ${TF_VAR_splunk_hec_tls:-On}" >&2
  fi
fi
export TF_VAR_splunk_hec_tls="${TF_VAR_splunk_hec_tls:-On}"

STATE="${TF_STATE_PATH:-$HERE/terraform.tfstate}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-}"
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"; mkdir -p "$TF_PLUGIN_CACHE_DIR"

if [[ "${1:-}" == "init" ]]; then shift; exec terraform init -backend-config="path=$STATE" "$@"; fi
if [[ ! -d .terraform ]] || ! grep -q "\"path\": \"$STATE\"" .terraform/terraform.tfstate 2>/dev/null; then
  terraform init -input=false -reconfigure -backend-config="path=$STATE" >/dev/null
fi
exec terraform "$@"
