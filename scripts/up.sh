#!/usr/bin/env bash
# Bring the lab back after a Docker restart, a reboot, or a `wsl --shutdown`.
# This is the recovery you have now done by hand three times, as one command.
#
#   ./scripts/up.sh          bring everything up, print what to start by hand
#   ./scripts/up.sh --check  read-only health check, no changes

source "$(dirname "$0")/lib.sh"
CHECK_ONLY=0; [[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

step "Docker"
if ! docker info >/dev/null 2>&1; then
  die "Docker daemon unreachable. Start Docker Desktop on Windows, wait for the whale to settle, re-run."
fi
ok "daemon up"

step "Containers"
for c in bhn-sim-control-plane splunk; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  case "$st" in
    running) ok "$c running" ;;
    missing) [[ "$c" == splunk ]] && warn "splunk container not created yet (Day 3)" || die "kind node container missing — ./scripts/03-cluster-up.sh" ;;
    *) if (( CHECK_ONLY )); then warn "$c is $st"; else docker start "$c" >/dev/null && ok "$c started (was $st)"; fi ;;
  esac
done

step "kubeconfig"
# kind publishes the API server on a random host port; it moves on every container
# restart. The stale one presents as 'connection refused' or, memorably, a Jenkins
# login page.
if (( ! CHECK_ONLY )); then kind export kubeconfig --name "$CLUSTER_NAME" >/dev/null 2>&1 || true; fi
for _ in $(seq 1 24); do
  kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1 && break; sleep 5
done
kubectl --context "$KUBE_CONTEXT" get nodes --no-headers 2>/dev/null | grep -q ' Ready ' \
  && ok "node Ready on context $KUBE_CONTEXT" \
  || die "API server not answering after 2 minutes. Try: docker restart bhn-sim-control-plane; sleep 30; $0"

step "Tombstones from the last crash"
if (( ! CHECK_ONLY )); then
  n=$(k get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l)
  (( n > 0 )) && { k delete pods -A --field-selector=status.phase=Failed >/dev/null 2>&1; ok "removed $n Failed pods"; } || ok "none"
fi

step "Workloads"
BAD=$(k get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)
[[ -z "$BAD" ]] && ok "every pod Running or Completed" || { warn "not healthy:"; echo "$BAD" | sed 's/^/    /'; }
k get deploy -n "$PAYMENTS_NS" -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas 2>/dev/null | sed 's/^/  /'

step "Incident knobs at baseline?"
drift=0
chk() { local v; v=$(k get deploy "$1" -n "$PAYMENTS_NS" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$2\")].value}" 2>/dev/null || true)
        [[ -z "$v" ]] && return 0
        [[ "$v" == "$3" ]] && ok "$1 $2=$v" || { warn "$1 $2=$v (baseline $3) — an experiment did not roll back"; drift=1; }; }
chk activation ERROR_RATE 0.02; chk activation BASE_LATENCY_MS 80; chk activation FRAUD_SVC_DOWN false
chk egift DELIVERY_DELAY_MS 40; chk egift EMAIL_FAIL_RATE 0.01
if (( drift )) && (( ! CHECK_ONLY )); then
  dim "Resetting to baseline (kubectl set env)..."
  k set env deployment/activation -n "$PAYMENTS_NS" ERROR_RATE=0.02 BASE_LATENCY_MS=80 FRAUD_SVC_DOWN=false >/dev/null
  k get deploy egift -n "$PAYMENTS_NS" >/dev/null 2>&1 && k set env deployment/egift -n "$PAYMENTS_NS" DELIVERY_DELAY_MS=40 EMAIL_FAIL_RATE=0.01 >/dev/null
  ok "reset"
fi

step "Front doors"
for p in 30080 30443; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://localhost:$p/healthz" || echo 000)
  [[ "$code" == 200 ]] && ok "localhost:$p -> 200" || warn "localhost:$p -> $code"
done

step "Host"
free -g | awk 'NR==2{printf "  memory: %s GB available of %s\n",$7,$2}'
powershell.exe -NoProfile -Command 'Get-PSDrive C | ForEach-Object { "  C: free {0:N1} GB" -f ($_.Free/1GB) }' 2>/dev/null || true

step "Not automated — start these in their own terminals"
say "  #2  ./scripts/12-loadgen.sh          activation traffic"
say "  #6  ./scripts/33-loadgen-egift.sh    egift orders           (Day 4+)"
say "  #3  ./scripts/06-grafana.sh          Grafana on :3000"
dim "Port-forwards and load generators do not survive a Docker restart; everything else now does."
