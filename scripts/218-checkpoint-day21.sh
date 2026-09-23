#!/usr/bin/env bash
# Day 21 exit criteria — the chores, and Mission Control's API with the safety on.
# Uses a short-lived port-forward (the API server's service proxy cannot carry our bearer token).
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18040; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }; trap cleanup EXIT
mc(){ curl -s -m 10 -H "Authorization: Bearer $(cat "$TOKF")" -H "X-Operator: checkpoint" -H "X-Entrance: api" \
          -H 'Content-Type: application/json' "$@"; }
jq_py(){ python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }

step "Day 21 exit criteria — Step 1, the chores"
[[ "$(bot_get /readyz | jq_py 'print(d.get("store"))')" == sqlite ]] && t_ok "incident-bot: SQLite store (readyz)" || t_fail "incident-bot not on the SQLite store — Jenkins SERVICE=incident-bot"
[[ "$(rem_get /signatures | jq_py 'print(d.get("state"))')" == sqlite ]] && t_ok "remediator: proposals + cooldowns in SQLite" || t_fail "remediator not on SQLite state — Jenkins SERVICE=remediator"
N=$(promql 'count(loadgen_rate_multiplier)' | jq_py 'print(int(float(d["data"]["result"][0]["value"][1])))' || echo 0)
[[ "$N" == 2 ]] && t_ok "loadgen: two targets scraped, RATE_MULTIPLIER visible" || t_fail "loadgen_rate_multiplier: $N series (want 2) — Jenkins SERVICE=loadgen"
k get deploy loadgen -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null | grep -qE 'loadgen:[0-9]+ loadgen:[0-9]+' \
  && t_ok "loadgen shipped through the pipeline ($(k get deploy loadgen -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}'))" || t_fail "loadgen not deployed by Jenkins"

step "Step 2-5 — mission-control, deployed like everything else"
IMG=$(k get deploy mission-control -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ "$IMG" =~ ^mission-control:[0-9]+$ ]] && t_ok "deployed by the pipeline: $IMG" || t_fail "mission-control not deployed by Jenkins (image: ${IMG:-none})"
[[ "$(k get deploy mission-control -n "$PAYMENTS_NS" -o jsonpath='{.spec.replicas}/{.status.readyReplicas}' 2>/dev/null)" == 1/1 ]] && t_ok "one replica, ready" || t_fail "mission-control not 1/1 ready"
[[ "$(k get pvc mission-control-data -n "$PAYMENTS_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == Bound ]] && t_ok "audit log on a PVC (Bound)" || t_fail "PVC mission-control-data not Bound"
head -1 docs/mission-control.md 2>/dev/null | grep -q 'One action catalog, three entrances' && t_ok "the design rule is the first line of docs/mission-control.md" || t_fail "docs/mission-control.md must open with the rule"

step "RBAC — the API server's answer"
SA="system:serviceaccount:${PAYMENTS_NS}:mission-control"
[[ "$(k auth can-i delete deployments -n "$PAYMENTS_NS" --as="$SA" 2>/dev/null)" == no ]] && t_ok "cannot delete deployments" || t_fail "mission-control CAN delete deployments"
[[ "$(k auth can-i get secrets -n "$PAYMENTS_NS" --as="$SA" 2>/dev/null)" == no ]] && t_ok "cannot read secrets" || t_fail "mission-control CAN read secrets"
[[ "$(k auth can-i patch deployments -n "$PAYMENTS_NS" --as="$SA" 2>/dev/null)" == yes ]] && t_ok "can patch deployments (rollback / set_fault)" || t_fail "cannot patch deployments — the catalog will fail"
if k get deploy mission-control -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  OUT=$(k exec -n "$PAYMENTS_NS" deploy/mission-control -- kubectl -n "$PAYMENTS_NS" delete deployment activation --dry-run=server 2>&1 || true)
  echo "$OUT" | grep -qi forbidden && t_ok "from inside the pod: 'kubectl delete deployment activation' is Forbidden" || t_fail "from inside the pod the delete was NOT forbidden: $OUT"
fi

step "The API — through a port-forward on :$PORT"
[[ -s "$TOKF" ]] || { t_fail "no ~/.bhn-sim/mc-token — ./scripts/210-mc-config.sh"; step "Score"; say "passed: $PASS   failed: $FAIL"; exit 1; }
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
B="http://localhost:$PORT"
[[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$B/api/overview")" == 401 ]] && t_ok "no token -> 401 (auth on by default)" || t_fail "/api/overview without a token did not 401"
OV=$(mc "$B/api/overview")
MS=$(echo "$OV" | jq_py 'print(d["ms"])' || echo 99999)
OKS=$(echo "$OV" | jq_py 'print(sum(1 for k in ("health","alerts","incidents","approvals","traffic") if d[k]["ok"]))' || echo 0)
(( MS < 2000 )) && [[ "$OKS" == 5 ]] && t_ok "/api/overview: one JSON, ${MS} ms, health/alerts/incidents/approvals/traffic all ok" || t_fail "/api/overview: ${MS} ms, $OKS/5 core tiles ok — $(echo "$OV" | head -c 300)"

# the audit log already holds the drill (DAY21 Step 5): a tier 1 ok, a tier 2 ok WITH its token
AUD=$(mc "$B/api/audit?limit=500")
echo "$AUD" | jq_py 'import sys; sys.exit(0 if any(r["tier"]==1 and r["result"]=="ok" and r["operator"]!="checkpoint" for r in d) else 1)' \
  && t_ok "audit: a tier-1 action executed, with an operator" || t_fail "audit: no tier-1 'ok' row — run one (DAY21 Step 5)"
echo "$AUD" | jq_py 'import sys; sys.exit(0 if any(r["tier"]==2 and r["result"]=="ok" and r["approval_token"] for r in d) else 1)' \
  && t_ok "audit: a tier-2 action executed after approval, token recorded" || t_fail "audit: no approved tier-2 row — run the fraud drill (DAY21 Step 5)"

# tier 2 without approval does nothing — proved live, then cleaned up
BEFORE=$(k get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.replicas}')
TOK=$(mc -X POST "$B/api/actions/scale" -d '{"params":{"service":"egift","replicas":3},"reason":"checkpoint: must NOT happen"}' | jq_py 'print(d["token"])' || true)
sleep 5
AFTER=$(k get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.replicas}')
[[ -n "$TOK" && "$BEFORE" == "$AFTER" ]] && t_ok "tier 2 without approval does nothing (egift stayed at $AFTER replicas)" || t_fail "tier-2 request changed the cluster or was not queued (before $BEFORE, after $AFTER, token ${TOK:-none})"
[[ -n "$TOK" ]] && mc -X POST "$B/api/approvals/$TOK/decline" -d '{}' >/dev/null
[[ -n "$TOK" ]] && [[ "$(mc -o /dev/null -w '%{http_code}' -X POST "$B/api/approvals/$TOK/approve" -d '{}')" =~ ^(404|502)$ ]] \
  && t_ok "a declined token cannot be approved afterwards (single use)" || t_fail "the declined token still worked"

step "Step 5 — the event stream"
curl -s -m 5 -H "X-Entrance: api" "http://localhost:$PORT/api/events" -o /dev/null -w '%{http_code}' | grep -q 401 && t_ok "/api/events refuses without a token" || t_fail "/api/events open without a token"
# Alertmanager >= 0.25 prints every webhook url as "<secret>" in /api/v2/status (CORRECTIONS-DAY21 N7),
# so the URL is read from the config the operator generated, and delivery is proved by the metric below.
SEC=$(k get secret -n "$MONITORING_NS" -o name | sed 's|secret/||' | grep -E '^alertmanager-.*-generated$' | head -1 || true)
k get secret "$SEC" -n "$MONITORING_NS" -o jsonpath='{.data.alertmanager\.yaml\.gz}' 2>/dev/null | base64 -d | gunzip 2>/dev/null \
  | grep -q 'mission-control.payments:8040/hooks/alertmanager' && t_ok "Alertmanager's third webhook -> mission control (Terraform, operator-generated config)" || t_fail "Alertmanager does not route to mission control — k8s/kps-values.yaml + ./infra/local/tf.sh apply"
H=$(promql 'sum(mc_alertmanager_webhooks_total)' | jq_py 'print(int(float(d["data"]["result"][0]["value"][1])))' || echo 0)
(( H > 0 )) && t_ok "the feed has received $H Alertmanager notification(s)" || t_fail "no notification has reached the feed yet — the fraud drill (DAY21 Step 5)"

step "Shipped"
set +e; ./infra/local/tf.sh plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1; RC=$?; set -e
(( RC == 0 )) && t_ok "terraform plan clean" || t_fail "terraform plan exit $RC — ./infra/local/tf.sh plan"
[[ -f CORRECTIONS-DAY21.md ]] && t_ok "CORRECTIONS-DAY21.md ($(grep -c '^### ' CORRECTIONS-DAY21.md) entries)" || t_fail "no CORRECTIONS-DAY21.md"
[[ -z "$(git status --porcelain)" ]] && t_ok "working tree clean" || t_fail "uncommitted changes"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 21 done. The platform has a control plane." || { warn "Not done yet."; exit 1; }
