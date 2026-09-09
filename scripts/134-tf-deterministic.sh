#!/usr/bin/env bash
# Day 13, Step 5c — make the plan deterministic and secret-free, so the nightly drift check
# can be trusted (CORRECTIONS-DAY13 B9, B10).
#
# Turning on the helm provider's manifest diff (B8) is what makes drift visible. It has two
# consequences this script settles:
#
#   B10  kps showed drift on every plan: with no adminPassword, the Grafana subchart renders
#        a RANDOM one and relies on Helm's `lookup` to keep the old one on a real upgrade —
#        and `lookup` returns nothing in a dry run. Fix: the password moves to a Secret we
#        own (secret/grafana-admin), minted here from the chart's own secret, so the value
#        you log in with does not change. The chart renders no secret; the plan is stable.
#   B9   rendered manifests now live in Terraform state and in plan output (Jenkins archives
#        plan.txt). The HEC token was in the Fluent Bit values -> it would be in both. Fix:
#        Fluent Bit reads it from secret/splunk-hec as ${SPLUNK_HEC_TOKEN}; 22-fluent-bit.sh
#        creates that Secret and renders a values file with no token in it.
#
# Both are one `terraform apply`. Grafana's Deployment changes (the secret checksum), so
# Grafana restarts and — no persistence — forgets its service accounts: the bot's and the
# remediator's tokens are re-minted here (100, 120), dashboards are ConfigMaps (09).
#
# Usage: ./scripts/134-tf-deterministic.sh [HEC-TOKEN]   (default: the token from the current rendered values file)
source "$(dirname "$0")/lib.sh"
require_cluster; require_docker
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"

step "Preconditions"
[[ -f infra/local/terraform.tfstate ]] || die "no state — ./scripts/130-tf-import.sh first"
grep -q 'experiments' infra/local/providers.tf || die "providers.tf lacks experiments = { manifest = true } (B8)"
grep -q 'existingSecret: grafana-admin' k8s/kps-values.yaml || die "k8s/kps-values.yaml lacks the grafana.admin.existingSecret block (B10)"
grep -q 'SPLUNK_HEC_TOKEN' k8s/fluent-bit-values.yaml.tmpl || die "k8s/fluent-bit-values.yaml.tmpl still carries the token inline (B9)"

step "B10 — Grafana admin password into secret/grafana-admin (same value you use today)"
if k get secret grafana-admin -n "$MONITORING_NS" >/dev/null 2>&1; then
  ok "secret/grafana-admin exists"
else
  PW=$(k get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || true)
  [[ -n "$PW" ]] || die "cannot read the current password from secret/kps-grafana"
  k create secret generic grafana-admin -n "$MONITORING_NS" \
    --from-literal=admin-user=admin --from-literal=admin-password="$PW" >/dev/null
  unset PW
  ok "secret/grafana-admin minted from the chart's secret (value unchanged, not shown)"
fi

step "B9 — HEC token into secret/splunk-hec, values re-rendered without it"
TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  TOKEN=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' k8s/fluent-bit-values.yaml 2>/dev/null | head -1 || true)
  [[ -n "$TOKEN" ]] || TOKEN=$(k get secret splunk-hec -n "$LOGGING_NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
fi
[[ -n "$TOKEN" ]] || die "no HEC token: pass it as \$1 (Splunk > Settings > Data Inputs > HTTP Event Collector)"
"$LAB_ROOT/scripts/22-fluent-bit.sh" "$TOKEN" 2>&1 | grep -E '^\s*(ok|warn|==>)' | sed 's/^/  /' || true
unset TOKEN
grep -qE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' k8s/fluent-bit-values.yaml && die "the rendered values file still contains a token — is the template patched?" || ok "rendered values file carries no token"

step "Plan — expect exactly kps (Grafana secret) and fluent_bit (env from Secret)"
set +e; "$TF" plan -input=false -no-color -detailed-exitcode > infra/local/plan.txt 2>&1; RC=$?; set -e
(( RC != 1 )) || die "plan failed: $(tail -5 infra/local/plan.txt)"
# a clean plan has no 'will be' line: grep exits 1, and under pipefail+set -e that ended the
# script with no message the first time (the 22-fluent-bit.sh lesson, again) — hence || say
grep -nE 'will be|Plan:' infra/local/plan.txt | sed 's/^/  /' || say "  (no changes — already applied)"
grep -q 'helm_release.pushgateway will be' infra/local/plan.txt && warn "pushgateway is in the plan — the drift drill is not repaired (./scripts/132-drift-drill.sh repair)"
if (( RC == 2 )); then
  echo; read -rp "  Read it. Apply? [Enter = yes, Ctrl-C = no] " _
  step "Apply"
  set +e; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1; RC=$?; set -e
  grep -E '^(helm_release|Apply complete)|^\s*(│ )?Error:' infra/local/apply.txt | sed 's/^/  /' || true
  (( RC == 0 )) || die "terraform apply failed (exit $RC) — full output: infra/local/apply.txt"
else
  step "Apply — nothing to apply"
fi
k -n "$MONITORING_NS" rollout status deploy/kps-grafana --timeout=180s >/dev/null && ok "Grafana rolled (new pod, same password)"
k -n "$LOGGING_NS" rollout status ds/fluent-bit --timeout=120s >/dev/null && ok "Fluent Bit rolled (token from the Secret)"
sleep 5
if k logs -n "$LOGGING_NS" -l app.kubernetes.io/name=fluent-bit --tail=20 2>/dev/null | grep -qiE '\b(401|403)\b|invalid token'; then
  die "Fluent Bit reports an auth error — is secret/splunk-hec the right token? kubectl -n logging logs ds/fluent-bit"
fi
ok "no HEC auth errors in Fluent Bit's log"

step "Grafana forgot its service accounts (no persistence) — re-minting the bot's and the remediator's tokens"
"$LAB_ROOT/scripts/100-enrich-config.sh" 2>&1 | grep -E '^\s*(ok|warn|die)' | sed 's/^/  /' || warn "100-enrich-config.sh had trouble — run it by hand"
"$LAB_ROOT/scripts/120-remediator-config.sh" 2>&1 | grep -E '^\s*(ok|warn)' | head -6 | sed 's/^/  /' || warn "120-remediator-config.sh had trouble — run it by hand"
"$LAB_ROOT/scripts/09-grafana-dashboards.sh" >/dev/null 2>&1 && ok "dashboards re-applied (ConfigMaps; the sidecar reloads them)" || warn "09-grafana-dashboards.sh failed — run it by hand"

step "Proof — the plan is clean, and nothing secret is in state"
set +e; "$TF" plan -input=false -detailed-exitcode >/dev/null 2>&1; RC=$?; set -e
case "$RC" in 0) ok "plan clean (exit 0) — deterministic: the nightly check can be trusted";; 2) warn "plan still not clean — ./infra/local/tf.sh plan and read it";; *) die "plan failed";; esac
T=$(k get secret splunk-hec -n "$LOGGING_NS" -o jsonpath='{.data.token}' | base64 -d)
G=$(grafana_admin_password)
grep -q -- "$T" infra/local/terraform.tfstate && die "the HEC token is STILL in terraform.tfstate" || ok "HEC token: not in state"
grep -q -- "$G" infra/local/terraform.tfstate && die "the Grafana password is in terraform.tfstate" || ok "Grafana password: not in state"
unset T G
rm -f infra/local/terraform.tfstate.backup && ok "terraform.tfstate.backup removed (the last state that carried the token)"

step "Commit"
git add k8s/kps-values.yaml k8s/fluent-bit-values.yaml.tmpl infra/local scripts
git commit -q -m "Day 13: deterministic, secret-free plan — Grafana admin via existingSecret, HEC token via Secret env (B9, B10)" && ok "committed $(git log -1 --format=%h)"
ok "Next: ./scripts/133-drift-check-job.sh --prove"
