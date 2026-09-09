#!/usr/bin/env bash
# Day 14, Step 2 — runbook rot. The README is read at 3 AM by someone who trusts it; this
# checks every command, port, job and load-bearing fact in it against the running lab.
# Runbook rot is the default state of documentation; a 30-second audit after every intense
# week is the countermeasure.
#
#   ./scripts/141-readme-audit.sh          audit
#   ./scripts/141-readme-audit.sh --quiet  only the failures (for the checkpoint)
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
Q=0; [[ "${1:-}" == "--quiet" ]] && Q=1
PASS=0; FAIL=0
a_ok()   { PASS=$((PASS+1)); (( Q )) || ok "$*"; }
a_fail() { FAIL=$((FAIL+1)); warn "$*"; }
R=README.md

step "Every script the README names exists and is executable"
# ./scripts/NN-name.sh anywhere in the file (code blocks, tables, prose)
mapfile -t SCRIPTS < <(grep -oE '(\./)?scripts/[0-9]+-[a-z0-9-]+\.sh' "$R" | sed 's|^\./||' | sort -u)
for f in "${SCRIPTS[@]}"; do
  if [[ -x "$f" ]]; then a_ok "$f"; elif [[ -f "$f" ]]; then a_fail "$f exists but is not executable (chmod +x)"; else a_fail "$f named in README but MISSING"; fi
done
mapfile -t TOOLS < <(grep -oE 'tools/[a-z_]+\.py' "$R" | sort -u)
for f in "${TOOLS[@]}"; do [[ -f "$f" ]] && a_ok "$f" || a_fail "$f named in README but MISSING"; done
mapfile -t DOCS < <(grep -oE '(docs|incidents|gameday|ci|k8s|infra/local)/[A-Za-z0-9_./-]+\.(md|yaml|yml|tf|sh|json|xml|txt)\b' "$R" | grep -v 'tfstate' | sort -u)
for f in "${DOCS[@]}"; do [[ -e "$f" ]] && a_ok "$f" || a_fail "$f linked from README but MISSING"; done

step "Scripts that exist but the README never mentions (undocumented = does not exist at 3 AM)"
UNDOC=0
for f in scripts/[0-9]*.sh; do
  grep -q "$(basename "$f")" "$R" || { a_fail "$f is not in the README"; UNDOC=1; }
done
(( UNDOC )) || a_ok "every script is documented"

step "Ports the README promises answer"
port() { local p=$1 path=$2 want=$3 code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://localhost:$p$path" 2>/dev/null); code=${code:-000}
         [[ "$code" =~ $want ]] && a_ok "localhost:$p -> $code" || a_fail "localhost:$p -> $code (README says it is there: $4)"; }
port 8081 /login '^(200|403)$' Jenkins
port 8000 /     '^(200|303)$' "Splunk web"
port 30080 /healthz '^200$' "activation NodePort"
port 30443 /healthz '^200$' "egift NodePort"
curl -s -o /dev/null --max-time 3 http://localhost:3000/api/health && a_ok "localhost:3000 (Grafana port-forward) up" || (( Q )) || dim "  localhost:3000 not up — a port-forward, not a fault (06-grafana.sh)"

step "Jenkins jobs the README names exist"
for j in deploy-service infra-drift-check; do
  grep -q "$j" "$R" || continue
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://localhost:8081/job/$j/" 2>/dev/null || echo 000)
  [[ "$code" =~ ^(200|403)$ ]] && a_ok "Jenkins job $j" || a_fail "Jenkins job $j named in README but HTTP $code"
done

step "Load-bearing facts, checked against the cluster"
# Alertmanager repeat_interval the README states vs the live config
# -m1, not | head -1: head closing the pipe early gives grep SIGPIPE under pipefail (Day 13, N7)
# the STATEMENT is backticked (`repeat_interval 6h`); the Day 13 command comment ("4h -> 6h") is not
want=$(grep -m1 -oE '`repeat_interval [0-9]+h`' "$R" | tr -d '`' | awk '{print $2}')
live=$(alertmanager_get /api/v2/status | grep -m1 -oE 'repeat_interval: [0-9]+h' | awk '{print $2}')
[[ -n "$want" && "$want" == "$live" ]] && a_ok "repeat_interval: README says $want, Alertmanager says $live" || a_fail "repeat_interval: README says '$want', Alertmanager says '$live'"
# the Grafana password source
if k get secret grafana-admin -n "$MONITORING_NS" >/dev/null 2>&1; then
  grep -q 'grafana-admin' "$R" && a_ok "README knows the Grafana password lives in secret/grafana-admin" || a_fail "README does not mention secret/grafana-admin (Day 13, B10)"
fi
# ownership: Terraform owns the platform layer -> README must not send people to helm for kps
grep -q 'Terraform owns' "$R" && a_ok "ownership boundary stated" || a_fail "no 'Terraform owns' ownership table"
if grep -nE '^\| Routing \|' "$R" | grep -q '81-alertmanager-route.sh' && ! grep -nE '^\| Routing \|' "$R" | grep -q 'tf.sh'; then
  a_fail "Routing row still sends changes through helm (81) — Terraform owns kps since Day 13"
else a_ok "routing changes go through tf.sh"; fi
# deployed image tags vs what the README claims
for svc in activation egift settlement incident-bot remediator; do
  img=$(k get deploy "$svc" -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || k get cronjob "$svc" -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  [[ -n "$img" ]] || continue
  if grep -qE "\`$svc:0\.[0-9]\` — rebuild with" "$R"; then a_fail "$svc: README says a hand-built tag; the cluster runs $img (pipeline)"; else a_ok "$svc runs $img — README does not contradict it"; fi
done
# stale phrases that have bitten before
for bad in 'import into Grafana' 'HEC token supplied by the wrapper' 'kps-grafana' 'initialAdminPassword' 'repeat_interval 4h`'; do
  grep -qF "$bad" "$R" && a_fail "stale phrase: '$bad'" || a_ok "no '$bad'"
done
# the morning routine is linked (Day 14 prep)
grep -q 'docs/morning.md' "$R" && a_ok "docs/morning.md linked" || a_fail "docs/morning.md not linked from the README"

step "Result"
say "  ok: $PASS   rot: $FAIL"
if (( FAIL == 0 )); then ok "README matches reality. Note the date in the README's audit line and commit."; else warn "fix the lines above, then run this again"; exit 1; fi
