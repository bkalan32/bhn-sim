#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
export PYTHONPATH="$LAB_ROOT/services/incident-bot"
step "Day 17 exit criteria"
require_cluster

# Part A — New Relic, as code, proven from inside
[[ -f k8s/newrelic-values.yaml ]] && grep -q 'customSecretName: newrelic-license' k8s/newrelic-values.yaml && ! grep -qiE 'licenseKey: *[A-Za-z0-9]' k8s/newrelic-values.yaml && t_ok "newrelic-values.yaml: key by Secret reference, not in the file" || t_fail "k8s/newrelic-values.yaml missing or carries a key"
grep -q 'lowDataMode: true' k8s/newrelic-values.yaml && t_ok "low data mode on (ingest is the bill)" || t_fail "lowDataMode not on"
grep -q '_payments_' k8s/newrelic-values.yaml && t_ok "log forwarding: payments namespace only (Day 3 B4)" || t_fail "newrelic-logging tails the whole cluster"
grep -q 'helm_release" "newrelic"' infra/local/releases.tf && grep -qE '^\s*"newrelic"\s*=' infra/local/chart-versions.auto.tfvars && t_ok "nri-bundle is a pinned Terraform release ($(grep -oE '"newrelic"\s*=\s*"[0-9.]+"' infra/local/chart-versions.auto.tfvars))" || t_fail "nri-bundle not in releases.tf / not pinned"
grep -q 'remoteWrite' k8s/kps-values-newrelic.yaml && grep -q 'action: keep' k8s/kps-values-newrelic.yaml && t_ok "remote write with a keep-list (ingest cost control)" || t_fail "k8s/kps-values-newrelic.yaml: remote write / keep-list missing"
for ns in newrelic monitoring; do k get secret newrelic-license -n $ns >/dev/null 2>&1 && t_ok "secret/newrelic-license in $ns" || t_fail "secret/newrelic-license missing in $ns (170)"; done
NR=$(k get pods -n newrelic --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l); (( NR >= 3 )) && t_ok "New Relic agents running ($NR pods)" || t_fail "$NR agent pods Running in newrelic (171)"
OKS=$(promql 'sum(prometheus_remote_storage_samples_total{url=~".*newrelic.*"})' | python3 tools/promjson.py value '{:.0f}' 2>/dev/null || echo 0)
[[ "$OKS" =~ ^[0-9]+$ ]] && (( OKS > 0 )) && t_ok "remote write: $OKS samples accepted by New Relic (Prometheus's own counter)" || t_fail "remote write has not succeeded (171 --status)"
RC=0; ./infra/local/tf.sh plan -detailed-exitcode >/dev/null 2>&1 || RC=$?; (( RC == 0 )) && t_ok "infra/local plan clean (New Relic + remote write are code, not drift)" || t_fail "infra/local plan exit $RC"
N=$(grep -cE '^[0-9]+\. \S' docs/newrelic-notes.md 2>/dev/null || echo 0); (( N >= 10 )) && t_ok "docs/newrelic-notes.md: $N lines of judgment" || t_fail "docs/newrelic-notes.md: $N of 10 lines written (the numbered lines need words)"
grep -qE 'NR alert opened at [0-9]' docs/newrelic-notes.md 2>/dev/null && t_ok "the drill was seen in New Relic (evidence row filled)" || warn "newrelic-notes evidence: 'NR alert opened at …' not filled — the Step 3 dashboard + alert are UI work; fill the row"

# Part B — the knowledge base
K=$(python3 -c 'import kb; print(len(kb.load("kb")))' 2>/dev/null || echo 0); (( K >= 7 )) && t_ok "kb/: $K entries, all parse" || t_fail "kb/: $K valid entries (need 7; ./scripts/172-kb.sh validates)"
python3 - <<'PY' && t_ok "every KB entry cites a real incident write-up" || t_fail "a KB entry cites an incident that has no write-up"
import kb, os, sys
bad=[(e["id"],i) for e in kb.load("kb") for i in e["learned_from"] if not os.path.exists("incidents/%s.md" % i)]
print("  " + ", ".join("%s -> %s" % b for b in bad)) if bad else None
sys.exit(1 if bad else 0)
PY
grep -q 'kb_matches' services/incident-bot/ai.py && grep -q 'import kb' services/incident-bot/app.py && t_ok "bot: hypothesis prompt carries KB matches; /ai and /kb/search expose them" || t_fail "bot not wired to the KB"
grep -q 'mountPath: /kb' k8s/incident-bot.yaml && t_ok "bot manifest mounts the kb ConfigMap (optional)" || t_fail "k8s/incident-bot.yaml has no /kb mount"
grep -q '"search_kb"' tools/copilot.py && grep -q 'call search_kb' tools/copilot.py && t_ok "copilot: search_kb tool + the before-concluding rule" || t_fail "copilot not wired to the KB"
[[ -f services/incident-bot/tests/test_kb.py ]] && (cd services/incident-bot && python3 -m pytest -q tests/test_kb.py >/dev/null 2>&1) && t_ok "kb tests pass" || t_fail "services/incident-bot/tests/test_kb.py missing or failing"
bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin).get("kb") or {}; sys.exit(0 if d.get("ok") and len(d.get("entries",[]))>=7 else 1)' 2>/dev/null && t_ok "the running bot sees the KB (the Day 17 build is deployed)" || t_fail "the running bot has no KB — Jenkins SERVICE=incident-bot, then 172"
[[ -f incidents/INC-0019-diagnosis.md ]] && grep -qi 'kb-001' incidents/INC-0019-diagnosis.md && t_ok "INC-0019: the hypothesis cites kb-001" || t_fail "no incidents/INC-0019-diagnosis.md citing kb-001 (173)"
[[ -f incidents/INC-0019.md ]] && t_ok "incidents/INC-0019.md written" || t_fail "write incidents/INC-0019.md"
grep -q 'Eval 8' docs/ai-eval.md && grep -qE '^\| 0019 \|' docs/ops-kpis.md && t_ok "ai-eval Eval 8 + ops-kpis row 0019" || t_fail "docs/ai-eval.md Eval 8 / docs/ops-kpis.md row 0019"
grep -qi 'updates a KB entry or' README.md && t_ok "README: the KB maintenance rule" || t_fail "README lacks the KB maintenance rule"
git status --porcelain 2>/dev/null | grep -c . >/dev/null && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 17 done." || { warn "Not done yet."; exit 1; }
