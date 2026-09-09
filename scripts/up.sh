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
for c in bhn-sim-control-plane splunk jenkins; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  case "$st" in
    running) ok "$c running" ;;
    missing) case "$c" in
               splunk)  warn "splunk container not created yet (Day 3)" ;;
               jenkins) warn "jenkins container not created yet (Day 1/6)" ;;
               *)       die "kind node container missing — ./scripts/03-cluster-up.sh" ;;
             esac ;;
    *) if (( CHECK_ONLY )); then warn "$c is $st"; else docker start "$c" >/dev/null && ok "$c started (was $st)"; fi ;;
  esac
done

# Day 14: a monitoring tool must not be able to starve the platform it monitors. Re-assert
# Splunk's CPU cap every morning (docker update persists across restart, not re-creation).
if docker ps --format '{{.Names}}' | grep -qx splunk; then
  docker update --cpus 1.5 splunk >/dev/null 2>&1 && ok "splunk capped at 1.5 CPUs (its housekeeping took the whole VM on Day 14)" || warn "could not cap splunk's CPU"
fi

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

step "Ticket layer (Day 8)"
if k get deploy incident-bot -n "$PAYMENTS_NS" >/dev/null 2>&1; then
  [[ -n "$(bot_get /healthz)" ]] && ok "incident-bot answering" || warn "incident-bot deployed but not answering via proxy"
  alertmanager_get /api/v2/status | grep -q 'name: incident-bot' && ok "Alertmanager -> incident-bot route live" || warn "Alertmanager not routing to the bot — ./scripts/81-alertmanager-route.sh"
  n=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print("?")' 2>/dev/null || echo "?")
  [[ "$n" == 0 ]] && ok "no open incidents" || warn "$n open incident(s): python3 tools/inc.py list open"
  AIP=$(bot_get /ai | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(("%s/%s" % (d["provider"], d["model"])) if d.get("enabled") else "off")
except Exception: print("?")' 2>/dev/null || echo "?")
  [[ "$AIP" == off ]] && warn "AI drafts off (no provider) — ./scripts/90-ai-secret.sh   (Day 9+)" || ok "AI drafts: $AIP"
  # Day 12: the remediator — up, not in dry-run, fanned out, nothing waiting on a human
  if k get deploy remediator -n "$PAYMENTS_NS" >/dev/null 2>&1; then
    RS=$(rem_get /signatures | python3 -c 'import json,sys
try: d=json.load(sys.stdin); print("dry-run" if d.get("dry_run") else "live")
except Exception: print("?")' 2>/dev/null || echo "?")
    case "$RS" in live) ok "remediator answering (live)";; dry-run) warn "remediator in DRY_RUN — actions are only described";; *) warn "remediator deployed but not answering via proxy";; esac
    alertmanager_get /api/v2/status | grep -q remediator && ok "Alertmanager -> remediator fan-out live" || warn "Alertmanager not fanning out to the remediator — ./scripts/121-remediator-route.sh"
    np=$(rem_get /pending | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print("?")' 2>/dev/null || echo "?")
    [[ "$np" == 0 ]] && ok "no remediation proposals pending" || warn "$np proposal(s) waiting for a human: python3 tools/rem.py pending"
  fi
  # Day 10: Splunk's container IP moves on restart; the enrich-config secret pins it.
  if k get secret enrich-config -n "$PAYMENTS_NS" >/dev/null 2>&1; then
    SURL=$(k get secret enrich-config -n "$PAYMENTS_NS" -o jsonpath='{.data.SPLUNK_URL}' | base64 -d 2>/dev/null || true)
    SIP=$(splunk_ip)
    if [[ -n "$SIP" && "$SURL" == *"$SIP"* ]]; then ok "enrichment: Splunk at $SURL"
    else warn "enrichment: secret says $SURL but Splunk is at ${SIP:-<not running>} — ./scripts/100-enrich-config.sh"; fi
    # Day 13 lesson: Grafana keeps its service accounts in an emptyDir — a REPLACED Grafana pod
    # (helm upgrade, node restart) forgets the bot's and the remediator's tokens. Ask the bot
    # what its collectors see instead of trusting the secret exists.
    COLL=$(bot_get '/enrich/test?service=activation' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s=%s"%(k,"ok" if v.get("ok") else "FAIL") for k,v in d["collectors"].items()))' 2>/dev/null || true)
    if [[ -z "$COLL" ]]; then warn "bot did not answer /enrich/test"
    elif [[ "$COLL" == *FAIL* ]]; then warn "collectors: $COLL — deploys=FAIL means a dead Grafana token: ./scripts/100-enrich-config.sh && ./scripts/120-remediator-config.sh; logs=FAIL means Splunk"
    else ok "collectors: $COLL"; fi
  fi
else
  warn "incident-bot not deployed yet (Day 8)"
fi

step "Log pipeline (Day 3)"
# Fluent Bit ships to Splunk by container IP, rendered into its ConfigMap by 22-fluent-bit.sh.
# Splunk gets a new IP on every restart; a stale one means Splunk silently stops receiving.
FB_HOST=$(k get cm -n "$LOGGING_NS" -o yaml 2>/dev/null | grep -oE 'Host +[0-9.]+' | awk '{print $2}' | head -1 || true)
SIP=$(splunk_ip)
if [[ -z "$FB_HOST" ]]; then warn "fluent-bit not installed yet (Day 3)"
elif [[ -n "$SIP" && "$FB_HOST" == "$SIP" ]]; then ok "fluent-bit -> Splunk at $SIP"
elif [[ -f "$LAB_ROOT/infra/local/terraform.tfstate" ]]; then warn "fluent-bit ships to $FB_HOST but Splunk is at ${SIP:-<not running>} — Terraform owns the release now: ./infra/local/tf.sh apply   (renders the new IP; one change, the Host line)"
else warn "fluent-bit ships to $FB_HOST but Splunk is at ${SIP:-<not running>} — re-render: ./scripts/22-fluent-bit.sh <HEC-TOKEN>   (token: checkpoints/day3-splunk.txt or Splunk UI)"; fi

step "Platform layer (Day 13)"
if [[ -f "$LAB_ROOT/infra/local/terraform.tfstate" ]]; then
  if docker ps --format '{{.Names}}' | grep -qx splunk; then
    say "  terraform plan (renders five charts; ~30-60 s, 2-min cap; UP_SKIP_TF=1 to skip) ..."
    if [[ "${UP_SKIP_TF:-}" == 1 ]]; then RC=99; else
      set +e; timeout 120 "$LAB_ROOT/infra/local/tf.sh" plan -input=false -no-color -lock=false -detailed-exitcode > "$LAB_ROOT/infra/local/plan.txt" 2>&1; RC=$?; set -e
    fi
    case "$RC" in
      99)  dim "  skipped (UP_SKIP_TF=1) — ./infra/local/tf.sh plan when the VM is quiet" ;;
      124) warn "terraform plan took over 2 min and was stopped — the VM is busy (docker stats); ./infra/local/tf.sh plan later, or UP_SKIP_TF=1 $0" ;;
      0) ok "plan clean — the cluster matches infra/local" ;;
      2) warn "DRIFT: $(grep -cE 'will be updated' "$LAB_ROOT/infra/local/plan.txt" || true) release(s) differ — $(grep -E 'will be' "$LAB_ROOT/infra/local/plan.txt" | sed -E 's/.*# (helm_release|kubernetes_namespace)\.([a-z_]+).*/\2/' | tr '\n' ' ')"
         say "    after a restart this is usually Fluent Bit's Host line (Splunk moved): ./infra/local/tf.sh plan, read, ./infra/local/tf.sh apply" ;;
      *) warn "terraform plan failed (exit $RC): $(tail -3 "$LAB_ROOT/infra/local/plan.txt" | tr '\n' ' ')" ;;
    esac
  else warn "splunk not running — Terraform cannot render Fluent Bit's values; docker start splunk, then ./infra/local/tf.sh plan"; fi
  JT=$(docker run --rm --entrypoint sh jenkins-lab -c 'command -v terraform' 2>/dev/null || true)
  [[ -n "$JT" ]] && ok "Jenkins image carries terraform (infra-drift-check runs nightly, H 3 * * *)" || warn "Jenkins image lacks terraform — ./scripts/133-drift-check-job.sh rebuilds it"
else
  dim "  no Terraform state yet (Day 13)"
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
say "      python3 tools/inc.py list        incidents, any time     (Day 8+)"
say "  #3  ./scripts/06-grafana.sh          Grafana on :3000"
dim "Port-forwards and load generators do not survive a Docker restart; everything else now does."
