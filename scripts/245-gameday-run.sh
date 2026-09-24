#!/usr/bin/env bash
# Day 24 — save a game-day run's skeleton into the repo, after its Retro.
#
#   ./scripts/245-gameday-run.sh             list the runs the console knows (sealed ones say so)
#   ./scripts/245-gameday-run.sh <run-id>    write gameday/<run-id>.md from the console's skeleton
#
# The skeleton is the scribe's draft: what was injected and when (revealed at Retro), the incidents
# with MTTD measured from their injection, and the timeline from the kept feed. The judgement part
# at the bottom is yours — fill it in, then commit it with the INC write-ups.
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18042; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; }; trap cleanup EXIT
[[ -s "$TOKF" ]] || die "no ~/.bhn-sim/mc-token — ./scripts/210-mc-config.sh"
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
mc(){ curl -s -m 20 -H "Authorization: Bearer $(cat "$TOKF")" "$@"; }

if [[ -z "${1:-}" ]]; then
  step "Game-day runs"
  mc "localhost:$PORT/api/gameday" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["runs"]:
    print("  %s  %-12s %-8s started %s  %s" % (r["id"], r["scenario"], r["status"], r["started_at_iso"],
          "retro " + r["revealed_at_iso"] if r.get("revealed_at_iso") else "(sealed: press Retro in the console first)"))'
  exit 0
fi
RUN="$1"; [[ "$RUN" =~ ^run-[0-9TZ]{16}$ ]] || die "a run id looks like run-20260924T183204Z"
OUT="gameday/$RUN.md"
CODE=$(mc -o "$OUT.tmp" -w '%{http_code}' "localhost:$PORT/api/gameday/runs/$RUN/skeleton")
if [[ "$CODE" != 200 ]]; then rm -f "$OUT.tmp"; die "HTTP $CODE — $( [[ $CODE == 409 ]] && echo 'still sealed: press Retro first' || echo 'unknown run?')"; fi
if [[ -f "$OUT" ]] && ! cmp -s "$OUT" "$OUT.tmp"; then
  mv "$OUT.tmp" "$OUT.new"; warn "$OUT exists (you may have edited it) — the fresh skeleton is $OUT.new; merge by hand"
else
  mv "$OUT.tmp" "$OUT"; ok "wrote $OUT ($(wc -l < "$OUT") lines) — fill in 'For the retro', then commit"
fi
