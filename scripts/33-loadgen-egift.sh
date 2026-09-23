#!/usr/bin/env bash
# Day 4, Step 5 — corporate customers ordering eGifts. Runs alongside 12-loadgen.sh.
# Your platform now has two customer types: stores activating physical cards and
# corporates ordering eGifts.

source "$(dirname "$0")/lib.sh"
require_cluster

# Day 21: traffic runs in the cluster now (deployment/loadgen, k8s/loadgen.yaml). A laptop
# generator on top of it doubles the rate — a fake incident. Opt in explicitly.
if k get deployment loadgen -n "$PAYMENTS_NS" >/dev/null 2>&1 && [[ "${FORCE:-}" != 1 ]]; then
  die "deployment/loadgen is already sending traffic in the cluster — this would double it.
       Turn it up instead:  kubectl -n $PAYMENTS_NS set env deployment/loadgen -c activation RATE_MULTIPLIER=2
       Or, deliberately both:  FORCE=1 $0"
fi
RPS="${1:-3}"

k apply -f "$LAB_ROOT/k8s/egift.yaml" >/dev/null 2>&1 || true
step "Testing the NodePort path (localhost:30443)"
for _ in $(seq 1 10); do
  curl -fsS --max-time 2 http://localhost:30443/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 2 http://localhost:30443/healthz >/dev/null 2>&1 \
  || die "localhost:30443 not reachable. Are egift pods Running? kubectl get pods -n payments"
ok "using NodePort — survives rollouts, load-balances both pods"

step "Generating eGift orders (~${RPS}/s) — Ctrl-C to stop"
dim "Each order fans out to activation, so this ALSO adds ~${RPS} req/s to activation."
dim "Expect the activation dashboard to climb by that much. Status: 200 ok, 502 upstream/email, 504 timeout."
exec python3 "$LAB_ROOT/tools/loadgen.py" --payload egift --url http://localhost:30443/orders --rps "$RPS"
