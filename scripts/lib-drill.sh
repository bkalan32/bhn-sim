#!/usr/bin/env bash
# Shared pieces for the Day 10 drills (sourced after lib.sh). Not a script.

INC="$LAB_ROOT/tools/inc.py"

field() { bot_get "/incidents/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print(v if v else "")' "$2" 2>/dev/null || true; }
open_ids() { open_ids_for activation; }
open_ids_for() { bot_get '/incidents?status=open' | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: d=[]
print(" ".join(i["id"] for i in d if i.get("service")==sys.argv[1]))' "$1" 2>/dev/null || true; }
# Day 12: wait for a NEW open incident for any service. Prints its id.
wait_open_for() {  # service before limit
  local svc="$1" before="$2" limit="${3:-360}" t0 now cand id=""; t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    sleep 10; now="$(open_ids_for "$svc")"
    for cand in $now; do [[ " $before " == *" $cand "* ]] || id="$cand"; done
    [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
    printf '  t+%-4ss waiting for a %s ticket\n' "$(( $(date +%s) - t0 ))" "$svc" >&2
  done
  return 1
}
# Day 12: the [remediator] notes on a record, one per line, with times.
rem_notes() { python3 "$INC" timeline "$1" | grep -F '[remediator]' || true; }
err_now() { promql '100 * sum(rate(activation_requests_total{status="error"}[1m])) / clamp_min(sum(rate(activation_requests_total[1m])),0.001)' | python3 "$LAB_ROOT/tools/promjson.py" value '{:.0f}%'; }
box() { printf '%s\n' "$1" | sed 's/^/  │ /'; }
wait_field() { local v; for _ in $(seq 1 "$3"); do v=$(field "$1" "$2"); [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }; sleep 3; done; return 1; }

# Wait for a NEW open activation incident (not one of $1). Prints its id. Up to $2 seconds.
wait_open() {
  local before="$1" limit="${2:-360}" t0 now cand id="" ; t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    sleep 10; now="$(open_ids)"
    for cand in $now; do [[ " $before " == *" $cand "* ]] || id="$cand"; done
    [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
    printf '  t+%-4ss err=%s\n' "$(( $(date +%s) - t0 ))" "$(err_now)" >&2
  done
  return 1
}

wait_resolved() {  # id [limit]
  local limit="${2:-900}" t0 st; t0=$(date +%s)
  while (( $(date +%s) - t0 < limit )); do
    sleep 10; st=$(field "$1" status); [[ "$st" == "resolved" ]] && return 0
    (( ($(date +%s) - t0) % 30 < 10 )) && printf '  +%-4ss err=%-5s status=%s\n' "$(( $(date +%s) - t0 ))" "$(err_now)" "$st" >&2
  done
  return 1
}

show_context_and_hypothesis() {  # id
  step "Context the bot attached (what a human would have looked up)"
  python3 "$INC" context "$1"
  step "The AI's diagnosis (ai_hypothesis)"
  local h; if h=$(wait_field "$1" ai_hypothesis 40); then echo; box "$h"; echo; else warn "no hypothesis yet: python3 tools/inc.py hypothesis $1"; fi
}

write_diag_file() {  # id number title
  local out="$LAB_ROOT/incidents/INC-$2-diagnosis.md"
  {
    echo "# INC-$2 — $3 (generated $(date -u +%FT%TZ))"
    echo; echo "Record: \`$1\`"
    echo; echo "## Timeline"; echo; echo '```'; python3 "$INC" timeline "$1"; echo '```'
    echo; echo "## Context (enrichment)"; echo; echo '```'; python3 "$INC" context "$1"; echo '```'
    echo; echo "## ai_hypothesis"; echo; echo '```'; field "$1" ai_hypothesis; echo '```'
    echo; echo "## ai_open_draft"; echo; echo '```'; field "$1" ai_open_draft; echo '```'
    echo; echo "## ai_resolution_draft"; echo; echo '```'; field "$1" ai_resolution_draft; echo '```'
    echo; echo "## Meta"; echo; echo '```'
    bot_get "/incidents/$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps({"ai_meta": d.get("ai_meta",{}), "context_meta": d.get("context_meta",{})}, indent=2))'
    echo '```'
  } > "$out"
  ok "$out"
}
