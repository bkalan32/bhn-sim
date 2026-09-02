#!/usr/bin/env bash
# Day 1, Step 5 — deploy nginx, reach it, delete it.
#
# The point is the habit, not the nginx: confirm the platform itself is healthy
# before blaming an application. This is the first thing you do on a real page.
#
# Difference from the guide: the guide has you open a second terminal and curl by hand.
# This backgrounds the port-forward, curls, and always cleans up — including on Ctrl-C.

source "$(dirname "$0")/lib.sh"
require_cluster

PF_PID=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  k delete deployment web --ignore-not-found --wait=false >/dev/null 2>&1 || true
  k delete svc web        --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

step "Deploying nginx"
k create deployment web --image=nginx >/dev/null
k expose deployment web --port=80 >/dev/null
k rollout status deployment/web --timeout=120s

step "Port-forwarding svc/web to localhost:8080"
k port-forward svc/web 8080:80 >/dev/null 2>&1 &
PF_PID=$!
sleep 3

step "Curling it"
if BODY=$(curl -fsS --max-time 10 http://localhost:8080); then
  echo "$BODY" | head -5
  ok "Got HTML back — the platform serves traffic."
else
  die "No response on localhost:8080. Check 'kubectl get pods' and that the port is free."
fi

step "Cleaning up"
dim "(handled by the exit trap — deployment and service are removed)"
ok "Smoke test passed. Next: scripts/05-install-monitoring.sh"
