#!/usr/bin/env bash
# Day 2, Step 6 — your fake store network. Leave this running all day.
#
# Two delivery paths, tried in order:
#
#   1. NodePort on localhost:30080  (preferred)
#      Routes through kube-proxy: load-balances across BOTH replicas and survives
#      rolling restarts, so `14-mini-incident.sh` does not knock your traffic out.
#
#   2. Supervised port-forward on localhost:8000  (fallback)
#      Used when the kind cluster has no 30080 host mapping. `kubectl port-forward`
#      pins ONE pod and dies when that pod is replaced, so this path runs it under a
#      restart loop. You will still see a few seconds of errors during a rollout --
#      that is the port-forward reconnecting, not the service failing.

source "$(dirname "$0")/lib.sh"
require_cluster

# Day 21: traffic runs in the cluster now (deployment/loadgen, k8s/loadgen.yaml). A laptop
# generator on top of it doubles the rate — a fake incident. Opt in explicitly.
if k get deployment loadgen -n "$PAYMENTS_NS" >/dev/null 2>&1 && [[ "${FORCE:-}" != 1 ]]; then
  die "deployment/loadgen is already sending traffic in the cluster — this would double it.
       Turn it up instead:  kubectl -n $PAYMENTS_NS set env deployment/loadgen -c activation RATE_MULTIPLIER=2
       Or, deliberately both:  FORCE=1 $0"
fi

RPS="${1:-8}"
PF_PID=""; SUP_PID=""
cleanup() {
  [[ -n "$SUP_PID" ]] && kill "$SUP_PID" 2>/dev/null || true
  [[ -n "$PF_PID"  ]] && kill "$PF_PID"  2>/dev/null || true
}
trap cleanup EXIT INT TERM

step "Ensuring the NodePort service exists"
k apply -f "$LAB_ROOT/k8s/activation-nodeport.yaml" >/dev/null
ok "svc/activation-nodeport -> nodePort 30080"

step "Is anything behind it?"
# Rebuild (CORRECTIONS-REBUILD B5): with no activation pods the NodePort refuses connections
# exactly like a cluster with no 30080 host mapping, and this script used to blame the
# mapping and fall back to :8000 (which Splunk's web UI holds). Ask for endpoints first.
EP=$(k get endpoints activation-nodeport -n "$PAYMENTS_NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
[[ -n "$EP" ]] || die "no activation pods behind the NodePort yet — nothing to send traffic to.
       Deploy activation first (Jenkins deploy-service SERVICE=activation; on a first deploy
       tick SKIP_VERIFY), then re-run this. A first deploy's Verify needs traffic; traffic
       needs a first deploy — SKIP_VERIFY once breaks the loop."
ok "endpoints: $EP"

step "Testing the NodePort path"
URL=""
for _ in $(seq 1 10); do
  if curl -fsS --max-time 2 http://localhost:30080/healthz >/dev/null 2>&1; then
    URL="http://localhost:30080/activate"; break
  fi
  sleep 1
done

if [[ -n "$URL" ]]; then
  ok "localhost:30080 reachable — using NodePort"
  dim "This path load-balances across both pods and survives rollouts, so you can run"
  dim "scripts/14-mini-incident.sh without the traffic dropping out."
else
  warn "localhost:30080 not reachable — your kind cluster has no host mapping for it."
  warn "Falling back to a supervised port-forward on :8000."
  dim  "To get the better path permanently, recreate the cluster with the config in"
  dim  "kind/bhn-sim-cluster.yaml:  ./scripts/99-teardown.sh && ./scripts/03-cluster-up.sh"
  dim  "(then re-run 11-deploy-activation.sh). Not required today."

  if ss -ltn 2>/dev/null | grep -q ':8000 '; then
    die "Port 8000 is already in use — most likely a stale 'uvicorn app:app --port 8000'
       or an old port-forward. Stop it, then re-run.
       Find it with: ss -ltnp | grep 8000     kill it with: kill \$(lsof -t -i:8000)"
  fi

  # Supervisor: restart the port-forward whenever it dies (i.e. on every rollout).
  (
    while true; do
      kubectl --context "$KUBE_CONTEXT" port-forward svc/activation \
        -n "$PAYMENTS_NS" 8000:8000 >/dev/null 2>&1 || true
      sleep 2
    done
  ) &
  SUP_PID=$!
  sleep 3
  URL="http://localhost:8000/activate"
  curl -fsS --max-time 3 http://localhost:8000/healthz >/dev/null 2>&1 \
    || die "port-forward never came up. Are the pods Running? kubectl get pods -n payments"
  ok "localhost:8000 reachable — supervised port-forward running"
fi

step "Generating traffic (~${RPS} req/s) — Ctrl-C to stop"
dim "Watch for 'unreachable' lines: that means traffic is NOT arriving, which looks"
dim "identical to a healthy run in the PDF's version of this script."
exec python3 "$LAB_ROOT/tools/loadgen.py" --url "$URL" --rps "$RPS"
