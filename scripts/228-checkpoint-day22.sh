#!/usr/bin/env bash
# Day 22 exit criteria — the Overview, the incident page, an approval from the banner, INC-0023.
# The browser work itself is proven by what it leaves behind: audit rows with entrance=button.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18040; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }; trap cleanup EXIT
mc(){ curl -s -m 10 -H "Authorization: Bearer $(cat "$TOKF")" -H "X-Operator: checkpoint" -H "X-Entrance: api" "$@"; }
jq_py(){ python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }
gexec(){ k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- "$@" 2>/dev/null; }

step "The image — API and UI in one container, shipped by the pipeline"
IMG=$(k get deploy mission-control -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ "$IMG" =~ ^mission-control:[0-9]+$ ]] && t_ok "deployed by the pipeline: $IMG" || t_fail "mission-control not deployed by Jenkins (image: ${IMG:-none})"
[[ -s "$TOKF" ]] || { t_fail "no ~/.bhn-sim/mc-token — ./scripts/210-mc-config.sh"; step "Score"; say "passed: $PASS   failed: $FAIL"; exit 1; }
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
B="http://localhost:$PORT"
HDRS=$(curl -s -m 5 -D - -o /tmp/mc-root.$$ "$B/" || true)
grep -q '<div id="root">' /tmp/mc-root.$$ && t_ok "GET / serves the UI" || t_fail "GET / is not the UI — this image predates Day 22"
echo "$HDRS" | grep -qi "content-security-policy:.*frame-src http://localhost:3000" && t_ok "the page has a CSP: iframes from Grafana only, fetch/SSE to itself only" || t_fail "no CSP (or frame-src is not Grafana) on /"
rm -f /tmp/mc-root.$$
ASSET=$(curl -s -m 5 "$B/" | grep -o '/assets/[^"]*\.js' | head -1 || true)
[[ -n "$ASSET" && "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$B$ASSET")" == 200 ]] && t_ok "the bundle loads ($ASSET)" || t_fail "the UI's JS bundle does not load"

step "Overview — live scores, a live feed, embedded Grafana"
OV=$(mc "$B/api/overview" || true)
N=$(echo "$OV" | jq_py 'print(len(d["sparklines"]["data"].get("activation", [])))' || echo 0)
# The range, not the point count, is what Day 22 changed: a 30-minute query can return at most 31
# points, so > 31 proves the hour. The count itself is only as long as Prometheus's unbroken
# history — after a restart it grows back one point a minute (CORRECTIONS-DAY22 N7).
(( N > 31 )) && t_ok "1-hour sparklines ($N points; 61 once Prometheus has an unbroken hour)" || t_fail "sparklines: $N points — the overview still asks for 30 minutes (want a 1 h range)"
EV=$(curl -s -N -m 20 "$B/api/events?access_token=$(cat "$TOKF")" 2>/dev/null || true)
echo "$EV" | grep -q '^event: hello' && echo "$EV" | grep -q '^event: health' && t_ok "the feed streams (hello + a health push within 20 s) — updates without reload" \
  || t_fail "no health event on /api/events within 20 s"
CFG=$(mc "$B/api/config" || true)
echo "$CFG" | jq_py 'import sys; sys.exit(0 if len(d["embed_panels"]) >= 4 else 1)' && t_ok "/api/config lists $(echo "$CFG" | jq_py 'print(len(d["embed_panels"]))') panels to embed" || t_fail "/api/config has no embed_panels"
XFO=$(gexec curl -s -D - -o /dev/null "http://localhost:3000/d-solo/bhn-activation/panel?orgId=1&panelId=5" | tr -d '\r' || true)
echo "$XFO" | grep -qi '^x-frame-options: deny' && t_fail "Grafana still sends X-Frame-Options: deny — k8s/kps-values.yaml grafana.ini + tf.sh apply" \
  || t_ok "Grafana allows embedding (no X-Frame-Options: deny)"
ANON=$(gexec curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/dashboards/uid/bhn-activation || true)
[[ "$ANON" == 200 ]] && t_ok "an anonymous Viewer can read the dashboards (what an iframe is)" || t_fail "anonymous dashboard read: HTTP $ANON — auth.anonymous in kps-values.yaml"
gexec curl -s http://localhost:3000/api/dashboards/uid/bhn-activation | jq_py 'import sys; ids={p.get("id") for p in d["dashboard"]["panels"]}; sys.exit(0 if {5,6,7} <= ids else 1)' \
  && t_ok "panel ids 5/6/7 pinned in the provisioned dashboard (./scripts/09-grafana-dashboards.sh)" || t_fail "panel ids not pinned in Grafana's copy — ./scripts/09-grafana-dashboards.sh"
[[ "$(gexec curl -s http://localhost:3000/api/admin/settings -o /dev/null -w "%{http_code}")" != 200 ]] && t_ok "…and cannot read the admin settings (refused)" || t_fail "anonymous can read /api/admin/settings — org_role must be Viewer"

step "The incident page's data"
KBN=$(mc "$B/api/kb" | jq_py 'print(sum(1 for e in d if e.get("fix")))' || echo 0)
(( KBN >= 5 )) && t_ok "/api/kb: $KBN entries with their fix text (the KB chips and the tier-3 card)" || t_fail "/api/kb: $KBN entries — CORRECTIONS-DAY22 B1"
AUD=$(mc "$B/api/audit?limit=1000" || true)
echo "$AUD" | jq_py 'import sys; sys.exit(0 if any(r["action"]=="note" and r["entrance"]=="button" and r["result"]=="ok" for r in d) else 1)' \
  && t_ok "a note posted from the incident page (tier 1, entrance=button, audited with a name)" || t_fail "no note from the browser yet (DAY22 Step 3)"
echo "$AUD" | jq_py 'import sys; sys.exit(0 if any(r["action"]=="rate_draft" and r["entrance"]=="button" for r in d) else 1)' \
  && t_ok "an AI draft graded from the page (eval row)" || t_fail "no thumbs up/down yet (DAY22 Step 3)"
EVN=$(mc "$B/api/eval" | jq_py 'print(len(d))' || echo 0)
(( EVN > 0 )) && t_ok "$EVN eval row(s) in mission control's table" || t_fail "no eval rows"

step "An approval granted from the pending banner"
echo "$AUD" | jq_py 'import sys; sys.exit(0 if any(r["tier"]==2 and r["result"]=="ok" and r["entrance"]=="button" and r["approval_token"] and r["operator"] not in ("checkpoint","") for r in d) else 1)' \
  && t_ok "a tier-2 action executed by a button click, with the approver's name and the token" || t_fail "no tier-2 approval from the browser yet (DAY22 Step 3)"

step "INC-0023 and the ship"
[[ -f incidents/INC-0023.md ]] && grep -qi "without a terminal" incidents/INC-0023.md && t_ok "INC-0023: first incident handled without a terminal" || t_fail "incidents/INC-0023.md missing (or without its note)"
set +e; ./infra/local/tf.sh plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1; RC=$?; set -e
(( RC == 0 )) && t_ok "terraform plan clean (Grafana embedding is Terraform's)" || t_fail "terraform plan exit $RC — ./infra/local/tf.sh plan"
[[ -f CORRECTIONS-DAY22.md ]] && t_ok "CORRECTIONS-DAY22.md ($(grep -c '^### ' CORRECTIONS-DAY22.md) entries)" || t_fail "no CORRECTIONS-DAY22.md"
[[ -z "$(git status --porcelain)" ]] && t_ok "working tree clean" || t_fail "uncommitted changes"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 22 done. The platform has a screen." || { warn "Not done yet."; exit 1; }
