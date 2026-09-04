#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 8 exit criteria"

# 1. bot in the cluster, reachable, scraped
[[ -n "$(bot_get /healthz)" ]] && t_ok "incident-bot answers via the API proxy" || t_fail "incident-bot not reachable"
PVC=$(k get pvc incident-bot-data -n "$PAYMENTS_NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[[ "$PVC" == "Bound" ]] && t_ok "records on a PersistentVolume (Bound)" || t_fail "PVC not Bound"
V=$(promql 'incidents_open' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}')
[[ "$V" != "no data" ]] && t_ok "incidents_open scraped (= $V)" || t_fail "incidents_open not in Prometheus"

# 2. Alertmanager routes to it
alertmanager_get /api/v2/status | grep -q 'incident-bot.payments:8020' && t_ok "Alertmanager live config has the incident-bot webhook" || t_fail "Alertmanager not routing to the bot"

# 3. a real drill opened AND auto-resolved with a timeline
DRILL=$(bot_get '/incidents?status=resolved' | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
hits=[i for i in d if i.get("service")=="activation" and i.get("duration_min") is not None]
print(hits[0]["id"] if hits else "")' 2>/dev/null || true)
[[ -n "$DRILL" ]] && t_ok "a resolved activation incident exists with duration ($DRILL)" || t_fail "no resolved activation incident — ./scripts/82-incident-drill.sh"

# 4. overview has the incident panels
grep -q 'incidents_open' "$LAB_ROOT/dashboards/overview.json" && t_ok "overview.json has the incidents row (re-import it if Grafana does not)" || t_fail "overview.json lacks incident panels"

# 5. settlement strict by default, 0.2 deployed
IMG=$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ "$IMG" != "settlement:0.1" && -n "$IMG" ]] && t_ok "settlement image is $IMG (not 0.1)" || t_fail "settlement still on 0.1"
grep -q 'value: "true"' "$LAB_ROOT/k8s/settlement.yaml" && t_ok "SETTLEMENT_STRICT=true in the manifest" || t_fail "manifest still has STRICT=false"

# 6. amount-mix test is ungated
grep -q 'TEST_PRODUCTION_AMOUNTS' "$LAB_ROOT/services/activation/tests/test_app.py" && t_fail "amount test still env-gated" || t_ok "amount-mix test always on"

# 7. new alerts loaded
if k get prometheusrule activation-alerts -n "$PAYMENTS_NS" -o yaml 2>/dev/null | grep -q EgiftHighLatency; then t_ok "EgiftHighLatency rule loaded (backlog #3)"; else t_fail "egift rules not applied"; fi

# 8. write-ups
grep -q 'fix verified' "$LAB_ROOT/incidents/INC-0005.md" 2>/dev/null && t_ok "INC-0005 has 'fix verified'" || t_fail "INC-0005.md lacks 'fix verified'"
grep -q 'fix verified' "$LAB_ROOT/incidents/INC-0006.md" 2>/dev/null && t_ok "INC-0006 has 'fix verified'" || t_fail "INC-0006.md lacks 'fix verified'"
[[ -s "$LAB_ROOT/incidents/INC-0007.md" ]] && t_ok "INC-0007.md exists (the drill write-up)" || t_fail "incidents/INC-0007.md missing"
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 8 complete. Day 9: the bot drafts the incident summary and stakeholder update with an LLM." || die "Not done yet."
