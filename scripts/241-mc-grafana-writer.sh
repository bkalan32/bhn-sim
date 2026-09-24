#!/usr/bin/env bash
# Day 24 — an Editor token for Mission Control, so a game-day run can stamp Grafana annotations.
#
# Mission Control reads Grafana with the incident bot's Viewer token (Day 10); a Viewer cannot write
# annotations. This mints a separate service account `mission-control` (Editor) and stores its token
# as GRAFANA_WRITE_TOKEN in secret/mission-control-config (merged — the Jenkins keys stay), never
# printed, then restarts mission-control. Missing = game days still run, without markers.
# Re-run it after Grafana's pod is REPLACED (it forgets service accounts — the up.sh "deploys=FAIL" case).
source "$(dirname "$0")/lib.sh"
require_cluster

step "Grafana: service account 'mission-control' (Editor) + token"
GPW=$(grafana_admin_password); [[ -n "$GPW" ]] || die "no Grafana admin password in secret/grafana-admin or secret/kps-grafana"
gcurl() { k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- curl -sf -u "admin:$GPW" -H 'Content-Type: application/json' "$@"; }
SA_ID=$(gcurl 'http://localhost:3000/api/serviceaccounts/search?query=mission-control' | python3 -c 'import json,sys; d=json.load(sys.stdin); h=[s for s in d.get("serviceAccounts",[]) if s["name"]=="mission-control"]; print(h[0]["id"] if h else "")' 2>/dev/null || true)
if [[ -z "$SA_ID" ]]; then
  SA_ID=$(gcurl -X POST http://localhost:3000/api/serviceaccounts -d '{"name":"mission-control","role":"Editor"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
  ok "service account 'mission-control' created (id $SA_ID, role Editor — annotations need write)"
else
  ok "service account 'mission-control' exists (id $SA_ID)"
fi
GTOKEN=$(gcurl -X POST "http://localhost:3000/api/serviceaccounts/$SA_ID/tokens" -d "{\"name\":\"mc-gameday-$(date +%s)\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
[[ -n "$GTOKEN" ]] || die "could not mint a Grafana token"
ok "token minted (not shown)"

step "Merging GRAFANA_WRITE_TOKEN into secret/mission-control-config"
k get secret mission-control-config -n "$PAYMENTS_NS" >/dev/null 2>&1 || die "no secret/mission-control-config — ./scripts/210-mc-config.sh first"
# stdin, not argv: the token never appears in a process list or the shell history
python3 -c 'import json,sys; print(json.dumps({"stringData": {"GRAFANA_WRITE_TOKEN": sys.stdin.read().strip()}}))' <<<"$GTOKEN" \
  | k patch secret mission-control-config -n "$PAYMENTS_NS" --type merge --patch-file /dev/stdin >/dev/null
unset GTOKEN
ok "stored (the Jenkins keys in the same secret are untouched)"

step "Restarting mission-control to pick it up"
k rollout restart deployment/mission-control -n "$PAYMENTS_NS" >/dev/null
k rollout status deployment/mission-control -n "$PAYMENTS_NS" --timeout=180s >/dev/null && ok "mission-control restarted" || warn "rollout not finished yet"
