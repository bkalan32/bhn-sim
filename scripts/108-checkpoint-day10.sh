#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
require_cluster
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 10 exit criteria"

bot_get /ai | grep -q '"enrich"' && t_ok "incident-bot 0.3 running ($(k get deploy incident-bot -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}'))" || t_fail "bot is not 0.3"
k get secret enrich-config -n "$PAYMENTS_NS" >/dev/null 2>&1 && t_ok "secret/enrich-config present" || t_fail "no enrich-config secret — ./scripts/100-enrich-config.sh"
if bot_get '/enrich/test?service=activation' | python3 -c 'import json,sys; c=json.load(sys.stdin)["collectors"]; sys.exit(0 if all(v.get("ok") for v in c.values()) else 1)' 2>/dev/null; then
  t_ok "all three collectors healthy right now"
else
  t_fail "a collector is degraded (./scripts/100-enrich-config.sh --check) — fine for the degradation test, not for 'done'"
fi

# the two drills: records with context AND a hypothesis, and the contrast
python3 - <<'PYCHK' && PASS=$((PASS+2)) || FAIL=$((FAIL+1))
import json, subprocess, sys
def get(p):
    r = subprocess.run(["kubectl","--context","kind-bhn-sim","get","--raw","/api/v1/namespaces/payments/services/incident-bot:8020/proxy"+p],capture_output=True,text=True)
    return json.loads(r.stdout) if r.returncode == 0 else []
incs = [get("/incidents/%s" % i["id"]) for i in get("/incidents?status=resolved") if i.get("service") == "activation"]
def deploys(i): return [d for d in (i.get("context") or {}).get("recent_deploys", []) if "text" in d]
def reasons(i): return [r.get("reason") or "" for r in (i.get("context") or {}).get("top_error_reasons", []) if "reason" in r]
def recent_bad(i): return any(0 <= (d.get("minutes_before_first_alert") or 99) <= 30 and "velocity" in (d.get("text") or "") for d in deploys(i))
ready = [i for i in incs if i.get("ai_hypothesis") and i.get("context")]
a = [i for i in ready if not recent_bad(i) and any("fraud" in r for r in reasons(i))]
b = [i for i in ready if recent_bad(i)]
print(("  ok   Drill A record: fraud_service_timeout in context, no recent deploy, hypothesis attached (%s)" % a[0]["id"]) if a else "  warn Drill A record not found — ./scripts/102-drill-a.sh")
print(("  ok   Drill B record: a velocity-check deploy <30 min before the alert, hypothesis attached (%s)" % b[0]["id"]) if b else "  warn Drill B record not found — ./scripts/103-drill-b.sh apply")
sys.exit(0 if (a and b) else 1)
PYCHK

[[ -s "$LAB_ROOT/incidents/INC-0009-diagnosis.md" && -s "$LAB_ROOT/incidents/INC-0010-diagnosis.md" ]] && t_ok "diagnosis files for both drills" || t_fail "INC-0009/0010-diagnosis.md missing"
[[ -s "$LAB_ROOT/incidents/INC-0009.md" && -s "$LAB_ROOT/incidents/INC-0010.md" ]] && t_ok "INC-0009.md and INC-0010.md exist" || t_fail "write-ups missing"
grep -q 'Eval 3' "$LAB_ROOT/docs/ai-eval.md" && ! sed -n '/## Eval 3/,/## Failures/p' "$LAB_ROOT/docs/ai-eval.md" | grep -q '_fill in_' && t_ok "docs/ai-eval.md Eval 3 graded" || t_fail "docs/ai-eval.md Eval 3 not graded"
grep -qE '^\| 00(09|10) \| `INC-[0-9]{10}-[0-9a-f]{4}`' "$LAB_ROOT/docs/ops-kpis.md" 2>/dev/null && t_ok "docs/ops-kpis.md has incident rows" || t_fail "docs/ops-kpis.md has no rows — python3 tools/kpis.py"

# drill B cleaned up
[[ "$(python3 "$LAB_ROOT/ci/amount_test_gate.py" status)" == enabled ]] && t_ok "amount-mix test re-enabled" || t_fail "amount-mix test still disabled — ./scripts/103-drill-b.sh revert"
grep -q 'velocity check (Day 6 bad release) BEGIN' "$LAB_ROOT/services/activation/app.py" && t_fail "velocity check still in app.py" || t_ok "velocity check removed"
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 10 complete. Day 11: an operational copilot that answers questions by querying Prometheus, Splunk and Kubernetes itself." || die "Not done yet."
