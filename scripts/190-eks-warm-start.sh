#!/usr/bin/env bash
# Day 19, Step 1 — the warm start, timed. Everything persists except the running
# infrastructure (Days 15/16), so the morning is a routine: network -> images -> cluster ->
# platform -> services -> the deltas since Day 16 (Days 17/18: the KB, the routing, the
# report) -> traffic -> the first brief. Each phase is one of the scripts you already have;
# this one only orders them, times them, and writes the number the README wants.
#
#   ./scripts/190-eks-warm-start.sh           run every phase (prompts: 152/160/162 'yes')
#   ./scripts/190-eks-warm-start.sh --from N  resume at phase N (1..8) after a fix
#   ./scripts/190-eks-warm-start.sh --status  what exists, what is missing, no changes
#
# Before it: the Day 19 bot build must exist on kind (Jenkins deploy-service SERVICE=incident-bot),
# because phase 2 pushes the bytes kind RUNS — the CloudWatch collector is in that image.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
require_aws
FROM=1; [[ "${1:-}" == --from ]] && FROM="$2"
T0=$(date +%s); TF0="$CHECKPOINTS/day19-warm-start.txt"
phase() { local n="$1"; shift; (( n >= FROM )) || return 1; PT=$(date +%s); CUR=$n; step "Phase $n/8 · $*  ($(( (PT - T0) / 60 )) min elapsed)"; }
mark()  { printf '  phase %s done: %s  (%s s)\n' "$1" "$2" "$(( $(date +%s) - PT ))" | tee -a "$TF0.log"; }
# A failed phase STOPS the warm start (a warm start that carries on past a failure is how the
# Day 16 env root survived a teardown). Fix, then: $0 --from N
fail() { die "phase $CUR failed — fix it, then: $0 --from $CUR"; }

if [[ "${1:-}" == --status ]]; then
  "$LAB_ROOT/scripts/152-aws-vpc.sh" status; "$LAB_ROOT/scripts/160-eks.sh" status 2>/dev/null || true
  KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/162-eks-platform.sh" status 2>/dev/null || true; exit 0
fi
(( FROM == 1 )) && { : > "$TF0.log"; echo "warm start begun $(date -u +%FT%TZ)" >> "$TF0.log"; }

getent hosts sts.us-east-2.amazonaws.com >/dev/null 2>&1 && ok "DNS answers (sts.us-east-2.amazonaws.com)" || die "DNS is not answering — the WSL relay (docs/morning.md step 0): sudo systemctl restart systemd-resolved"
if phase 1 "Network — infra/aws/env (VPC, NAT, ECR)"; then
  if "$LAB_ROOT/scripts/152-aws-vpc.sh" status 2>/dev/null | grep -q 'vpc-'; then ok "VPC exists — skipping apply"
  else "$LAB_ROOT/scripts/152-aws-vpc.sh" plan && "$LAB_ROOT/scripts/152-aws-vpc.sh" apply || fail; fi
  mark 1 "network"
fi

if phase 2 "Images — the bytes kind runs, pushed to ECR (Day 15's 153)"; then
  KB=$(kubectl --context kind-bhn-sim get deploy incident-bot -n payments -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  say "  kind runs $KB — the Day 19 bot (CloudWatch collector) must be in this tag: Jenkins deploy-service SERVICE=incident-bot first if not"
  kubectl --context kind-bhn-sim get nodes >/dev/null 2>&1 || fail_msg="kind is not answering — Docker Desktop / ./scripts/up.sh first (phase 2 mirrors the images kind runs)"
  [[ -n "${fail_msg:-}" ]] && { warn "$fail_msg"; fail; }
  kubectl --context kind-bhn-sim get --raw /api/v1/namespaces/payments/services/incident-bot:8020/proxy/ai 2>/dev/null | grep -q '"logs_backend"' \
    && ok "the bot on kind is the Day 19 build (reports logs_backend)" \
    || { warn "the bot on kind ($KB) predates Day 19 — no CloudWatch collector. Jenkins deploy-service SERVICE=incident-bot, then: $0 --from 2"; fail; }
  docker image inspect "$KB" >/dev/null 2>&1 && ok "image present in the local daemon" || warn "$KB not in the local daemon — 153 will rebuild it (slower, and check the arch)"
  "$LAB_ROOT/scripts/153-aws-ecr-push.sh" || fail
  mark 2 "images"
fi

if phase 3 "Cluster — infra/aws/eks (~12 min; + the bot's Pod Identity role, Day 19)"; then
  "$LAB_ROOT/scripts/160-eks.sh" plan && "$LAB_ROOT/scripts/160-eks.sh" apply && "$LAB_ROOT/scripts/161-eks-kubeconfig.sh" || fail
  mark 3 "cluster"
fi

if phase 4 "Platform — infra/aws/platform (CRDs, kps with Day 18's routing, Tempo, Fluent Bit -> CloudWatch, gp3)"; then
  KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/162-eks-platform.sh" plan && KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/162-eks-platform.sh" apply || fail
  mark 4 "platform"
fi

if phase 5 "Services — k8s/aws rendered from k8s/ + alerts + dashboards + the ticket layer wired (163)"; then
  KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/163-eks-deploy.sh" || fail
  mark 5 "services"
fi

if phase 6 "The deltas since Day 16 — KB ConfigMap (Day 17), routing verified with amtool (Day 18), logs collector = CloudWatch (Day 19)"; then
  KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/172-kb.sh" | tail -3
  KUBE_CONTEXT=aws-lab "$LAB_ROOT/scripts/181-alert-routing.sh" --verify | grep -E '^\s*(ok|warn|FAIL)' | tail -6
  say "  logs collector on EKS (the bot's /enrich/test, service=egift):"
  KUBE_CONTEXT=aws-lab bash -c 'source scripts/lib.sh; bot_get "/enrich/test?service=egift"' | python3 -c '
import json,sys; d=json.load(sys.stdin); m=d["collectors"]
for k,v in m.items(): print("  %-8s %s %6s ms  %s" % (k, "ok  " if v.get("ok") else "FAIL", v.get("latency_ms","-"), v.get("backend","") or v.get("error","")))
sys.exit(0 if all(v.get("ok") for v in m.values()) else 1)' && ok "three collectors of three — the first time on EKS (INC-0018's follow-up closed)" \
   || warn "a collector is down on EKS — logs: kubectl --context aws-lab -n payments logs deploy/incident-bot | grep -i cloudwatch; the Pod Identity association is in 160's plan (payments/incident-bot)"
  mark 6 "deltas"
fi

if phase 7 "Traffic — 164 in ANOTHER terminal; this phase only checks"; then
  say "  Terminal 2:  ./scripts/164-eks-traffic.sh          (port-forwards 18000/18010 + both load generators)"
  for _ in $(seq 1 24); do
    A=$(KUBE_CONTEXT=aws-lab bash -c 'source scripts/lib.sh; promql "sum(rate(activation_requests_total[2m]))"' | python3 tools/promjson.py value '{:.1f}' 2>/dev/null || echo 0)
    [[ "$A" != "no data" && "$A" != "0.0" && -n "$A" ]] && break; sleep 10
  done
  [[ "$A" != "no data" && "$A" != "0.0" && -n "$A" ]] && ok "activation traffic on EKS: $A req/s" || warn "no traffic yet — start 164 and re-run: $0 --from 7"
  mark 7 "traffic"
fi

if phase 8 "The first brief — the daily report against the fresh environment"; then
  KUBE_CONTEXT=aws-lab python3 tools/daily_report.py --day "$(date -u +%F)-eks-warm" | tail -12
  mark 8 "report"
  TOTAL=$(( ($(date +%s) - T0) / 60 ))
  printf 'warm start %s: %s min from network-up to a healthy brief (phases: %s)\n' "$(date -u +%F)" "$TOTAL" "$(grep -c 'done' "$TF0.log")" > "$TF0"
  cat "$TF0.log" | sed 's/^/  /'
  ok "WARM START: $TOTAL minutes — write it in README next to Day 1's 30-minute laptop rebuild (the checkpoint looks for the row)"
  ok "Next: read the brief's HEADLINE. 'healthy' → GAMEDAY_RUN=2 ./scripts/192-gameday2.sh start. Anything else → believe it, fix it first."
fi
