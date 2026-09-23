#!/usr/bin/env bash
# Day 22 — open Mission Control in your Windows browser. The ONE thing you run before a
# terminal-free session (game day 3): after this, the browser is the console.
#
#   ./scripts/220-mc-open.sh            start the two port-forwards (if not running), put the
#                                       token on the Windows clipboard, open the browser
#   ./scripts/220-mc-open.sh --status   which port-forwards are up
#   ./scripts/220-mc-open.sh --stop     stop them
#
# Two port-forwards, not one (CORRECTIONS-DAY22 D1): Mission Control :8040, and Grafana :3000
# because the embedded panels are iframes the BROWSER loads itself. Each runs in a loop that
# reconnects after a pod restart — a mission-control deploy during a drill must not leave you
# looking at a dead page with no terminal open to fix it.
#
# The token goes to the clipboard through clip.exe and is never printed; paste it into the
# login box once per browser tab (it lives in that tab's sessionStorage and nowhere else).
source "$(dirname "$0")/lib.sh"
require_cluster
MC_PORT="${MC_PORT:-8040}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
STATE="$HOME/.bhn-sim"
TOKF="$STATE/mc-token"
mkdir -p "$STATE"

up() { curl -s -o /dev/null -m 2 "http://localhost:$1$2"; }

start_pf() {  # name local-port namespace target remote-port health-path
  local name=$1 port=$2 ns=$3 target=$4 rport=$5 health=$6 pidf="$STATE/pf-$1.pid"
  if up "$port" "$health"; then ok "$name already on localhost:$port"; return; fi
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then kill -- -"$(cat "$pidf")" 2>/dev/null || true; fi
  # setsid: the loop gets its own process group, so --stop can end the loop AND its kubectl.
  setsid bash -c "while true; do kubectl --context '$KUBE_CONTEXT' -n '$ns' port-forward '$target' '$port:$rport' >>'$STATE/pf-$name.log' 2>&1; sleep 2; done" \
    </dev/null >/dev/null 2>&1 &
  echo $! > "$pidf"
  for _ in $(seq 1 20); do up "$port" "$health" && break; sleep 0.5; done
  up "$port" "$health" && ok "$name on localhost:$port (reconnects by itself)" || warn "$name not answering on :$port yet — $STATE/pf-$name.log"
}

stop_pf() {
  local pidf="$STATE/pf-$1.pid"
  if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill -- -"$(cat "$pidf")" 2>/dev/null && ok "stopped $1"
  else dim "  $1: not started by this script"; fi
  rm -f "$pidf"
}

case "${1:-}" in
  --stop) step "Stopping the port-forwards"; stop_pf mission-control; stop_pf grafana; exit 0 ;;
  --status)
    up "$MC_PORT" /healthz && ok "mission-control  http://localhost:$MC_PORT" || warn "mission-control not on :$MC_PORT"
    up "$GRAFANA_PORT" /api/health && ok "grafana          http://localhost:$GRAFANA_PORT" || warn "grafana not on :$GRAFANA_PORT"
    exit 0 ;;
esac

step "Mission Control is deployed?"
IMG=$(k -n "$PAYMENTS_NS" get deploy mission-control -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
[[ -n "$IMG" ]] || die "no deployment/mission-control — Jenkins deploy-service SERVICE=mission-control"
ok "$IMG"

step "Port-forwards"
start_pf mission-control "$MC_PORT" "$PAYMENTS_NS" svc/mission-control 8040 /healthz
start_pf grafana "$GRAFANA_PORT" "$MONITORING_NS" "svc/${HELM_RELEASE}-grafana" 80 /api/health

# The UI is in this image? (a Day-21 image answers `/` with JSON)
if curl -s -m 3 "http://localhost:$MC_PORT/" | grep -q '<div id="root">'; then ok "the UI is in $IMG"
else warn "$IMG has no UI — build mission-control through the pipeline (Day 22 image)"; fi

step "Token"
[[ -s "$TOKF" ]] || die "no $TOKF — ./scripts/210-mc-config.sh"
if have clip.exe; then
  clip.exe < "$TOKF" && ok "on your Windows clipboard (not printed) — paste it into the login box"
else
  warn "no clip.exe (not WSL?) — copy it yourself without printing it, e.g. xclip -sel c < $TOKF"
fi

URL="http://localhost:$MC_PORT/"
step "Open $URL"
if have explorer.exe; then explorer.exe "$URL" >/dev/null 2>&1 || true; ok "opened in your Windows browser"
else say "  open $URL"; fi
dim "  Sign in with your name + the token. Stop the port-forwards later: $0 --stop"
