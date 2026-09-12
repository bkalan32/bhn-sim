#!/usr/bin/env bash
# Day 18, Part B — the seven KPIs: computed, written into docs/ops-kpis.md, the queryable four
# on the overview dashboard.
#
#   ./scripts/182-kpis.sh              compute (7d), fill the table in docs/ops-kpis.md, render the dashboard row
#   ./scripts/182-kpis.sh --days 30    a different window
#   JENKINS_USER=admin JENKINS_PASS=... ./scripts/182-kpis.sh    also the deploy KPI (Jenkins needs auth)
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
require_cluster
DAYS=7; [[ "${1:-}" == --days ]] && DAYS="$2"
[[ -n "${JENKINS_PASS:-}" ]] || { read -rsp "Jenkins password for ${JENKINS_USER:-admin} (Enter to skip the deploy KPI): " JENKINS_PASS; echo; export JENKINS_PASS JENKINS_USER="${JENKINS_USER:-admin}"; }

step "1/3  The seven KPIs — last $DAYS days (tools/kpis.py --summary)"
python3 tools/kpis.py --summary --days "$DAYS" --json > /tmp/kpis.json || die "kpis.py failed (is the bot answering?)"
python3 tools/kpis.py --summary --days "$DAYS" | tee /tmp/kpis.md | sed 's/^/  /'

step "2/3  docs/ops-kpis.md — the current-values table between the markers"
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/ops-kpis.md"); s = p.read_text()
t = open("/tmp/kpis.md").read()
a, b = "<!-- kpis:start -->", "<!-- kpis:end -->"
if a in s and b in s:
    s = s[:s.index(a)+len(a)] + "\n" + t + "\n" + s[s.index(b):]; p.write_text(s); print("  ok   written")
else:
    print("  warn docs/ops-kpis.md has no kpis markers (Day 18 section missing?)")
PY

step "3/3  Overview dashboard — the KPI row (dashboards/overview.json -> ConfigMap -> Grafana)"
python3 -c "import json; d=json.load(open('dashboards/overview.json')); assert any('KPIs' in p.get('title','') for p in d['panels']), 'no KPI row in overview.json'" || die "dashboards/overview.json has no KPI row"
"$LAB_ROOT/scripts/09-grafana-dashboards.sh" >/dev/null 2>&1 && ok "dashboards re-rendered (09)" || warn "09-grafana-dashboards.sh returned non-zero — check Grafana"
PW=$(grafana_admin_password)
N=$(k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- curl -s -u "admin:$PW" 'http://localhost:3000/api/dashboards/uid/bhn-overview' 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)["dashboard"]; print(sum(1 for p in d["panels"] if "KPI" in p.get("title","") or "budget left" in p.get("title","") or "Remediated" in p.get("title","")))' 2>/dev/null || echo 0)
(( N >= 3 )) && ok "Grafana serves the KPI row ($N KPI panels) — Platform Overview, bottom" || warn "Grafana does not show the KPI row yet (sidecar lag ~30 s; re-run)"
ok "Next: python3 tools/daily_report.py   (Part C)"
