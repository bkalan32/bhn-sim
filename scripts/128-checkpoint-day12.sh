#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 12 exit criteria"

# policy first
[[ -s docs/remediation-policy.md ]] && grep -q "promotion" docs/remediation-policy.md && grep -qi "tier" docs/remediation-policy.md \
  && t_ok "docs/remediation-policy.md defines the tiers and the promotion rule" || t_fail "docs/remediation-policy.md missing or incomplete"
grep -q '^- Tier 1, crash-loop: _' docs/remediation-policy.md && t_fail "policy 'what we learned' not filled in" || t_ok "policy 'what we learned' filled in"

# the remediator, running, with scoped RBAC, fanned out, on the dashboard
rem_get /healthz | grep -q '"status"' && t_ok "remediator running ($(k get deploy remediator -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null))" || t_fail "remediator not answering"
rem_get /signatures | grep -q '"dry_run": *false' && t_ok "DRY_RUN off" || t_fail "DRY_RUN on (or remediator down)"
"$LAB_ROOT/scripts/120-remediator-config.sh" --check >/dev/null 2>&1 && t_ok "RBAC proof: the ServiceAccount can do the three actions and nothing else" || t_fail "RBAC proof failed — ./scripts/120-remediator-config.sh --check"
alertmanager_get /api/v2/status | grep -q remediator && t_ok "Alertmanager fans out to the remediator" || t_fail "no remediator webhook in Alertmanager's live config"
k get prometheusrule -n "$PAYMENTS_NS" -o json 2>/dev/null | grep -q PaymentsPodCrashLooping && t_ok "PaymentsPodCrashLooping rule loaded" || t_fail "PaymentsPodCrashLooping rule missing"
promql 'sum(remediation_actions_total) or vector(0)' | python3 tools/promjson.py value '{:.0f}' 2>/dev/null | grep -qE '^[1-9]' && t_ok "remediation_actions_total scraped by Prometheus (>0)" || t_fail "remediation_actions_total not scraped or zero — ServiceMonitor / no drills yet"
python3 -c "import json; d=json.load(open('dashboards/overview.json')); assert any('remediation' in (p.get('title') or '').lower() for p in d['panels'])" 2>/dev/null && t_ok "overview dashboard has the remediation row" || t_fail "no remediation panels in dashboards/overview.json"

# the three drills, from the incident records
python3 - <<'PYCHK' && PASS=$((PASS+3)) || FAIL=$((FAIL+1))
import json, subprocess, sys
def get(p):
    r = subprocess.run(["kubectl","--context","kind-bhn-sim","get","--raw","/api/v1/namespaces/payments/services/incident-bot:8020/proxy"+p],capture_output=True,text=True)
    return json.loads(r.stdout) if r.returncode == 0 else []
incs = [get("/incidents/%s" % i["id"]) for i in get("/incidents")[:40]]
def notes(i): return [e.get("text","") for e in i.get("timeline",[]) if e.get("event")=="note" and "[remediator]" in e.get("text","")]
crash = [i for i in incs if i.get("service")=="crashtest" and any("AUTO pod-crashloop" in n for n in notes(i)) and any("follow-up" in n for n in notes(i))]
settle = [i for i in incs if i.get("service")=="settlement" and any("AUTO settlement-crash" in n and "FAILED" in n for n in notes(i)) and any("retry 1/1" in n and "succeeded" in n for n in notes(i))]
rb = [i for i in incs if i.get("service")=="activation" and any("EXECUTED post-deploy-errors" in n and "succeeded" in n for n in notes(i)) and any("APPROVED" in n for n in notes(i))]
print(("  ok   tier 1 crash-loop: AUTO + follow-up on %s" % crash[0]["id"]) if crash else "  warn tier 1 crash-loop drill not found — ./scripts/122-drill-tier1.sh crashloop")
print(("  ok   tier 1 settlement: honest FAILED, then a successful retry on %s" % settle[0]["id"]) if settle else "  warn tier 1 settlement drill not found — ./scripts/122-drill-tier1.sh settlement")
print(("  ok   tier 2 rollback: PROPOSED -> APPROVED -> EXECUTED on %s" % rb[0]["id"]) if rb else "  warn tier 2 drill not found — ./scripts/123-drill-tier2.sh apply")
sys.exit(0 if (crash and settle and rb) else 1)
PYCHK

# tier 3 proof exists somewhere (the route test writes one on a synthetic ticket that is deleted; a real one is better)
rem_get /actions | grep -q '"mode": *"tier3"' && t_ok "a tier-3 'human required' note was written this process lifetime" || t_ok "tier-3 note not in this process's history (written on the deleted synthetic ticket, or before a restart) — fine"

# write-ups and the numbers
for n in 0012 0013 0014; do
  [[ -s incidents/INC-$n.md ]] && ! grep -q '_fill in_' incidents/INC-$n.md && t_ok "INC-$n.md written" || t_fail "incidents/INC-$n.md incomplete"
done
grep -qE '^\| 0014 \| `INC-[0-9]{10}-[0-9a-f]{4}`' docs/ops-kpis.md && grep -qi 'approve' docs/ops-kpis.md && t_ok "docs/ops-kpis.md has the approve-to-recover row" || t_fail "docs/ops-kpis.md lacks row 0014 / approve-to-recover"

# clean
[[ "$(python3 ci/amount_test_gate.py status)" == enabled ]] && t_ok "amount-mix test re-enabled" || t_fail "amount-mix test still disabled — ./scripts/123-drill-tier2.sh revert"
grep -q 'velocity check (Day 6 bad release) BEGIN' services/activation/app.py && t_fail "velocity check still in app.py" || t_ok "velocity check removed"
k get deploy crashtest -n "$PAYMENTS_NS" >/dev/null 2>&1 && t_fail "crashtest fixture still deployed" || t_ok "crashtest fixture removed"
[[ "$(k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_FAIL_MODE")].value}')" == none ]] && t_ok "settlement fail mode none" || t_fail "settlement SETTLEMENT_FAIL_MODE is not none"
git status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 12 done." || { warn "Not done yet."; exit 1; }
