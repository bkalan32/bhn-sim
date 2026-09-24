#!/usr/bin/env bash
# Day 24 — ship the game-day scenarios to the console.
#
#   ./scripts/240-gameday.sh          gameday/*.yaml -> ConfigMap `gameday` (mounted at /gameday in
#                                     mission-control), then wait until the console sees them
#   ./scripts/240-gameday.sh --check  what the console has loaded, and any scenario it refuses
#
# The scenarios are code: written in the repo, reviewed, committed — the console only RUNS them.
# A ConfigMap volume refreshes inside a running pod within ~1 minute, so no restart is needed.
# Mission Control validates every step with the set_fault validator; a broken file shows as broken
# on the Game Day page (and below), never silently missing.
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18041; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }; trap cleanup EXIT

loaded() {
  [[ -s "$TOKF" ]] || { warn "no ~/.bhn-sim/mc-token — ./scripts/210-mc-config.sh"; return 1; }
  k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -s -m 10 -H "Authorization: Bearer $(cat "$TOKF")" "localhost:$PORT/api/gameday" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for s in d.get("scenarios", []): print("  ok   %-12s %s" % (s["id"], s["title"]))
for f, e in (d.get("scenario_errors") or {}).items(): print("  FAIL %s: %s" % (f, e))
print("  annotations: " + ("on (Editor token present)" if d.get("annotations") else "OFF — ./scripts/241-mc-grafana-writer.sh"))
sys.exit(0 if d.get("scenarios") and not d.get("scenario_errors") else 1)'
}

if [[ "${1:-}" == --check ]]; then
  step "What the console has loaded"; loaded && exit 0 || exit 1
fi

step "gameday/*.yaml -> ConfigMap gameday"
files=(gameday/*.yaml)
[[ -e "${files[0]}" ]] || die "no gameday/*.yaml in the repo"
args=(); for f in "${files[@]}"; do args+=(--from-file="$f"); ok "$f"; done
k create configmap gameday -n "$PAYMENTS_NS" "${args[@]}" --dry-run=client -o yaml | k apply -f - >/dev/null
ok "ConfigMap gameday: ${#files[@]} scenario(s)"

step "Waiting for the console to see them (a ConfigMap volume refreshes within ~60 s)"
for i in $(seq 1 12); do
  if loaded 2>/dev/null >/tmp/gd.$$; then cat /tmp/gd.$$; rm -f /tmp/gd.$$; ok "loaded"; exit 0; fi
  cleanup; PF=""; sleep 10
done
cat /tmp/gd.$$ 2>/dev/null; rm -f /tmp/gd.$$
die "the console does not list them yet — is this mission-control image Day 24's (the /gameday mount)? kubectl -n payments describe pod -l app=mission-control"
