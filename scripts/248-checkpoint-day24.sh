#!/usr/bin/env bash
# Day 24 exit criteria — the Game Day console, KPIs, reports, the KB as cards, scenario-1 from the console.
# Like 228/238: the browser work is proven by what it left behind — audit rows, runs, evals, files.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18048; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; rm -f /tmp/c24.*.$$; }; trap cleanup EXIT
mc(){ curl -s -m 30 -H "Authorization: Bearer $(cat "$TOKF")" -H "X-Operator: checkpoint" -H "X-Entrance: api" "$@"; }
py(){ python3 -c "import json,sys; d=json.load(sys.stdin); $1" 2>/dev/null; }
gexec(){ k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- "$@" 2>/dev/null; }

step "The images"
for S in mission-control incident-bot; do
  IMG=$(k get deploy "$S" -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  [[ "$IMG" =~ ^$S:[0-9]+$ ]] && t_ok "$S deployed by the pipeline: $IMG" || t_fail "$S not deployed by Jenkins (image: ${IMG:-none})"
done
[[ -s "$TOKF" ]] || { t_fail "no ~/.bhn-sim/mc-token"; step "Score"; say "passed: $PASS   failed: $FAIL"; exit 1; }
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 20); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
B="http://localhost:$PORT"
AUD=$(mc "$B/api/audit?limit=3000" || echo '[]'); echo "$AUD" > /tmp/c24.aud.$$
GD=$(mc "$B/api/gameday" || echo '{}')

step "Step 1 — every knob from the console, tier 2, audited"
echo "$GD" | py '
import sys
k = d["knobs"]
if k.get("sealed"): print("sealed"); sys.exit(0)
n = sum(len(t.get("knobs", {})) for t in k.values() if not t.get("error"))
bad = [t for t, v in k.items() if v.get("error")]
print(n); sys.exit(0 if n == 8 and not bad else 1)' > /tmp/c24.k.$$ \
  && t_ok "the console reads all $(cat /tmp/c24.k.$$) knobs live (6 fault knobs + 2 traffic multipliers)" \
  || t_fail "the Game Day page cannot read every knob — $(cat /tmp/c24.k.$$ 2>/dev/null)"
python3 - /tmp/c24.aud.$$ <<'PY' && t_ok "a knob changed from the console: set_fault requested by button, executed after a human's Approve" || t_fail "no set_fault from the Game Day page yet (DAY24 step 6)"
import json, sys
d = json.load(open(sys.argv[1]))
pend = {r["approval_token"] for r in d if r["action"] == "set_fault" and r["result"] == "pending" and r["entrance"] in ("button", "command")}
sys.exit(0 if any(r["action"] == "set_fault" and r["result"] == "ok" and r["approval_token"] in pend for r in d) else 1)
PY
python3 - /tmp/c24.aud.$$ <<'PY' && t_ok "Reset all used (reset_faults, tier 1, ok)" || t_fail "reset_faults never ran — every game day ends with it"
import json, sys
sys.exit(0 if any(r["action"] == "reset_faults" and r["result"] == "ok" and r["tier"] == 1 for r in json.load(open(sys.argv[1]))) else 1)
PY

step "Step 1/5 — scenario-1 ran sealed from the console"
RUN=$(echo "$GD" | py '
r = [x for x in d["runs"] if x["scenario"] == "scenario-1" and not x["sealed"] and sum(s["state"] == "fired" for s in x.get("steps", [])) >= 2]
print(r[0]["id"] if r else "")' || true)
[[ -n "$RUN" ]] && t_ok "scenario-1 ran sealed and was revealed at Retro: $RUN (both steps fired)" || t_fail "no revealed scenario-1 run with both steps fired (DAY24 step 10)"
if [[ -n "$RUN" ]]; then
  python3 - /tmp/c24.aud.$$ "$RUN" <<'PY' && t_ok "its injections were audited sealed (run + step, never the knob) and revealed at Retro" || t_fail "sealed / revealed audit rows for $RUN missing"
import json, sys
d, run = json.load(open(sys.argv[1])), sys.argv[2]
sealed = [r for r in d if r["action"] == "scenario_step" and r["params"].get("run") == run]
revealed = [r for r in d if r["action"] == "scenario_step:set_fault" and run in (r["detail"] or "")]
sys.exit(0 if len(sealed) >= 2 and len(revealed) >= 2 and all(set(r["params"]) == {"run", "step"} for r in sealed) else 1)
PY
  [[ -f "gameday/$RUN.md" ]] && grep -q "What was injected" "gameday/$RUN.md" && t_ok "gameday/$RUN.md — the run skeleton is in the repo" \
    || t_fail "gameday/$RUN.md missing — ./scripts/245-gameday-run.sh $RUN"
  N=$(gexec curl -s "http://localhost:3000/api/annotations?tags=gameday&tags=$RUN&limit=50" | py 'print(len(d))' || echo 0)
  (( N >= 3 )) && t_ok "$N Grafana annotations for the run (start + each step), revealed text" || t_fail "only ${N:-0} gameday annotations for $RUN — ./scripts/241-mc-grafana-writer.sh"
  gexec curl -s "http://localhost:3000/api/annotations?tags=gameday&limit=200" | py '
import sys
svc = {"activation", "egift", "settlement", "incident-bot", "remediator", "loadgen"}
sys.exit(1 if any(set(a.get("tags", [])) & svc for a in d) else 0)' \
    && t_ok "no game-day annotation carries a service tag (the bot's deploy collector cannot see them)" || t_fail "a gameday annotation has a service tag — it would leak into the hypothesis"
fi
echo "$GD" | py 'import sys; sys.exit(0 if d.get("sealed_run") is None else 1)' && t_ok "nothing is sealed now (the game day was ended)" || t_fail "a run is still sealed — Retro, then Reset all"

step "Step 2 — KPIs, MTTD computed from the injections"
KP=$(mc "$B/api/kpis?fresh=true" || echo '{}')
echo "$KP" | py 'import sys; sys.exit(0 if len(d["tiles"]) == 7 and all(len(t["trend"]) == 4 and t["definition"] for t in d["tiles"]) else 1)' \
  && t_ok "7 KPI tiles, each with a 4-week trend and its definition" || t_fail "/api/kpis is not the seven tiles"
M=$(echo "$KP" | RUN="$RUN" py 'import os; r=[x for x in d["incidents"] if (x["ttd_source"] or "").startswith(os.environ["RUN"] or "run-")]; print(" ".join("%s=%ss" % (x["id"], x["ttd_s"]) for x in r))' || true)
[[ -n "$M" ]] && t_ok "MTTD from the console's injection times: $M" || t_fail "no incident with MTTD measured from ${RUN:-a console run}"

step "Step 3 — reports on demand, gradeable"
python3 - /tmp/c24.aud.$$ <<'PY' && t_ok "Generate now used from the console (generate_report, button)" || t_fail "no generate_report from the Reports page yet"
import json, sys
sys.exit(0 if any(r["action"] == "generate_report" and r["result"] == "ok" and r["entrance"] in ("button", "command") for r in json.load(open(sys.argv[1]))) else 1)
PY
R=$(mc "$B/api/eval" | py 'print(sum(1 for e in d if e["draft"] == "report"))' || echo 0)
(( R >= 3 )) && t_ok "$R report grades (three consecutive days read side by side)" || t_fail "$R report grade(s) — grade three days on the Reports page"

step "Step 4 — the KB page and the feeding rule"
mc "$B/api/kb" | py 'import sys; sys.exit(0 if len(d) >= 7 and all(e["id"] and e["checks"] and not e.get("error") for e in d) else 1)' \
  && t_ok "every KB entry renders as a card with its checks (same parser as the bot)" || t_fail "a KB entry does not parse — /api/kb"
F=$(mc "$B/api/kb-feeding" | py 'print(len(d))' || echo 0)
(( F >= 2 )) && t_ok "$F incident(s) with a KB decision (updated / not needed because …)" || t_fail "$F KB decisions — the feeding checkbox on INC-0024/0025"
mc "$B/api/overview" | py 'import sys; n=d["needs_human"]["data"]; sys.exit(0 if not n["stale_open"] else 1)' \
  && t_ok "no stale open incidents (the reboot leftovers were closed with a reason)" || t_fail "stale open incidents remain — Close as stale on each"

step "Step 5 — the write-ups"
for f in incidents/INC-0024.md incidents/INC-0025.md; do
  [[ -f "$f" ]] && t_ok "$f" || t_fail "$f missing"
done
[[ -f gameday/gap-list.md ]] && t_ok "gameday/gap-list.md — every time you left the browser, and why (Day 25's morning)" || t_fail "gameday/gap-list.md missing (write 'none' if there were none)"

step "The ship"
set +e; ./infra/local/tf.sh plan -input=false -no-color -detailed-exitcode >/dev/null 2>&1; RC=$?; set -e
(( RC == 0 )) && t_ok "terraform plan clean" || t_fail "terraform plan exit $RC — ./infra/local/tf.sh plan"
[[ -f CORRECTIONS-DAY24.md ]] && t_ok "CORRECTIONS-DAY24.md ($(grep -c '^### ' CORRECTIONS-DAY24.md) entries)" || t_fail "no CORRECTIONS-DAY24.md"
[[ -z "$(git status --porcelain)" ]] && t_ok "working tree clean" || t_fail "uncommitted changes"

step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 24 done. Breaking things has a console, and the console keeps the record." || { warn "Not done yet."; exit 1; }
