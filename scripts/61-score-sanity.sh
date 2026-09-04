#!/usr/bin/env bash
# Day 7, Step 3 — break something mildly and prove the score MOVES.
# A score that stays green while things are broken is worse than no score.
source "$(dirname "$0")/lib.sh"
require_cluster
BAD="${1:-0.10}"; GOOD=0.02; INJECTED=0
cleanup(){ if (( INJECTED )); then warn "reverting ERROR_RATE=$GOOD on exit"; kubectl --context "$KUBE_CONTEXT" set env deployment/activation -n "$PAYMENTS_NS" ERROR_RATE=$GOOD >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT INT TERM
score(){ promql "$1" | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}'; }
snap(){ printf '  activation=%-4s platform=%-4s\n' "$(score activation:health_score)" "$(score platform:health_score)"; }
step "Baseline"; snap
say "  Injecting ERROR_RATE=$BAD. With the PDF's formula this would read ~94 (green)."
say "  With ours: activation -> ~40 (red), platform -> ~75 (yellow), within ~3 min (5m window)."
read -rp "  Enter to inject. " _
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=$BAD"; INJECTED=1
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
step "Watching the score fall"
for i in $(seq 1 8); do sleep 30; printf '  t+%-4ss' "$((i*30))"; snap; done
step "Rolling back"
k set env deployment/activation -n "$PAYMENTS_NS" "ERROR_RATE=$GOOD"; INJECTED=0
k rollout status deployment/activation -n "$PAYMENTS_NS" --timeout=180s
for i in $(seq 1 8); do sleep 30; printf '  t+%-4ss' "$((i*30))"; snap; done
step "What the score does NOT tell you"
say "  Which thing broke. It said 'activation is unhealthy' — the dashboard said 'errors, not"
say "  latency', Splunk said 'issuer_declined'. Scores spot and rank. Dashboards diagnose."
