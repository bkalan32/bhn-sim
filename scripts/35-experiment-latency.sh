#!/usr/bin/env bash
# Day 4, Step 7 — two incidents that look identical on a dashboard.
#
#   A: the dependency is slow    (activation BASE_LATENCY_MS 80 -> 800)
#   B: our own step is slow      (egift DELIVERY_DELAY_MS   40 -> 800)
#
# Both push egift p95 to ~1s. Same graph. The trace tells them apart in five seconds.
#
# Usage: ./scripts/35-experiment-latency.sh A|B [hold_seconds]

source "$(dirname "$0")/lib.sh"
require_cluster

EXP="${1:-}"; HOLD="${2:-150}"
case "$EXP" in
  A|a) EXP=A; TARGET=activation; VAR=BASE_LATENCY_MS; BAD=800; GOOD=80 ;;
  B|b) EXP=B; TARGET=egift;      VAR=DELIVERY_DELAY_MS; BAD=800; GOOD=40 ;;
  *) die "Usage: $0 A|B [hold_seconds]" ;;
esac

PF_PROM=""; PF_TEMPO=""; INJECTED=0
# FIX: revert on exit, no matter how the script ends. You found out the hard way
# that an apiserver blip mid-drill left BASE_LATENCY_MS=800 in place for an hour.
# Real chaos tooling guarantees revert-on-exit; so does this now.
cleanup() {
  for p in "$PF_PROM" "$PF_TEMPO"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  if (( INJECTED )); then
    warn "exiting with the injection still applied — reverting $TARGET $VAR=$GOOD"
    kubectl --context "$KUBE_CONTEXT" set env "deployment/$TARGET" -n "$PAYMENTS_NS" "$VAR=$GOOD" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM
SVC="${PROM_SVC:-$(prom_svc || true)}"; [[ -n "$SVC" ]] || die "Prometheus service not found"
k port-forward "svc/$SVC" -n "$MONITORING_NS" 9090:9090 >/dev/null 2>&1 & PF_PROM=$!
k port-forward svc/tempo -n "$TRACING_NS" 3200:3200 >/dev/null 2>&1 & PF_TEMPO=$!
sleep 4

p95() {  # $1 = metric bucket name
  curl -fsS --get --data-urlencode "query=histogram_quantile(0.95, sum(rate(${1}[2m])) by (le))" \
    http://localhost:9090/api/v1/query | python3 "$LAB_ROOT/tools/promjson.py" value '{:.2f}s'
}
snapshot() { printf '  egift p95=%-8s activation p95=%-8s\n' "$(p95 egift_order_latency_seconds_bucket)" "$(p95 activation_latency_seconds_bucket)"; }

latest_waterfall() {
  local now start s tid
  now=$(date +%s); start=$((now-120))
  s=$(curl -fsS --get http://localhost:3200/api/search \
       --data-urlencode 'q={ resource.service.name = "egift" && name = "POST /orders" && status != error }' \
       --data-urlencode "start=$start" --data-urlencode "end=$now" --data-urlencode "limit=1" 2>/dev/null || echo '{}')
  tid=$(echo "$s" | python3 -c 'import json,sys; t=json.load(sys.stdin).get("traces",[]); print(t[0]["traceID"] if t else "")')
  [[ -n "$tid" ]] || { warn "no recent trace found"; return; }
  curl -fsS "http://localhost:3200/api/traces/$tid" | python3 "$LAB_ROOT/tools/tempojson.py" waterfall
}

step "Experiment $EXP — baseline"
snapshot
echo; say "A representative trace right now:"; latest_waterfall

step "Injecting: $TARGET $VAR=$BAD"
k set env "deployment/$TARGET" -n "$PAYMENTS_NS" "$VAR=$BAD"; INJECTED=1
k rollout status "deployment/$TARGET" -n "$PAYMENTS_NS" --timeout=180s

step "Holding ${HOLD}s — watch the eGift dashboard: p95 climbs toward ~1s"
for ((i=30; i<=HOLD; i+=30)); do sleep 30; printf '  t+%-4ss' "$i"; snapshot; done
[[ "$EXP" == "A" ]] && dim "(ActivationHighLatency will fire during A — p95 > 0.5s for 2m. Expected.)"

step "The dashboard says 'slow'. The trace says WHERE:"
latest_waterfall
echo
if [[ "$EXP" == "A" ]]; then
  say "  -> the activation span is the wide bar. Page the ACTIVATION team."
else
  say "  -> send_email is the wide bar; activation is normal. Page the EMAIL PROVIDER."
fi

step "Rolling back: $TARGET $VAR=$GOOD"
k set env "deployment/$TARGET" -n "$PAYMENTS_NS" "$VAR=$GOOD"; INJECTED=0
k rollout status "deployment/$TARGET" -n "$PAYMENTS_NS" --timeout=180s
for i in 1 2 3; do sleep 30; printf '  t+%-4ss' "$((i*30))"; snapshot; done

step "Write it up"
[[ "$EXP" == "A" ]] && say "  incidents/INC-0002.md" || say "  incidents/INC-0003.md"
dim "The point: both experiments produced the SAME dashboard. Only the trace told the truth."
