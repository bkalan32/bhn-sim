#!/usr/bin/env bash
# Day 16 — the fake store network, aimed at EKS. One terminal, both services.
#
# kind mapped NodePorts 30080/30443 onto localhost (Day 1's cluster config); EKS nodes are
# in private subnets with no host to map to, so traffic goes through port-forwards —
# supervised (restarted on every rollout, exactly like 12-loadgen.sh's fallback path) and
# on DIFFERENT local ports (18000/18010), because 30080/30443 are still kind's while it
# runs. The load generator is the same tools/loadgen.py, unchanged.
#
#   ./scripts/164-eks-traffic.sh [rps]     Ctrl-C stops both generators and both port-forwards
export KUBE_CONTEXT=aws-lab
source "$(dirname "$0")/lib.sh"
require_cluster
RPS="${1:-6}"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; pkill -f "port-forward svc/(activation|egift) -n payments 180" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

supervise_pf() {  # svc local remote
  ( while true; do kubectl --context "$KUBE_CONTEXT" port-forward "svc/$1" -n "$PAYMENTS_NS" "$2:$3" >/dev/null 2>&1 || true; sleep 2; done ) &
  PIDS+=($!)
}
step "Port-forwards (supervised): activation -> localhost:18000, egift -> localhost:18010"
for port in 18000 18010; do ss -ltn 2>/dev/null | grep -c ":$port " >/dev/null && die "port $port in use — an old 164 still running? pkill -f 'port-forward svc/activation'"; done
supervise_pf activation 18000 8000
supervise_pf egift 18010 8010
for _ in $(seq 1 15); do curl -fsS --max-time 2 http://localhost:18000/healthz >/dev/null 2>&1 && curl -fsS --max-time 2 http://localhost:18010/healthz >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 http://localhost:18000/healthz >/dev/null 2>&1 || die "activation not reachable through the port-forward — kubectl --context aws-lab get pods -n payments"
curl -fsS --max-time 2 http://localhost:18010/healthz >/dev/null 2>&1 || die "egift not reachable through the port-forward"
ok "both answering (a few 'unreachable' lines during a rollout = the port-forward reconnecting, not the service)"

step "Traffic: activation ~${RPS} req/s, egift ~$((RPS/2 > 0 ? RPS/2 : 1)) req/s — Ctrl-C to stop"
python3 "$LAB_ROOT/tools/loadgen.py" --url http://localhost:18000/activate --rps "$RPS" 2>&1 | sed 's/^/  [activation] /' &
PIDS+=($!)
python3 "$LAB_ROOT/tools/loadgen.py" --payload egift --url http://localhost:18010/orders --rps "$((RPS/2 > 0 ? RPS/2 : 1))" 2>&1 | sed 's/^/  [egift]      /' &
PIDS+=($!)
wait
