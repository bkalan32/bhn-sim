#!/usr/bin/env bash
# Save what the lab remembers into the repo BEFORE the cluster is destroyed.
# Mission Control's audit log, approvals, evals, copilot answers, game-day runs, kept feed and KB
# decisions live in SQLite on a PVC inside the kind cluster; the incidents and daily reports live in
# the incident bot. `kind delete cluster` deletes all of it. This writes it to records/<date>/ as JSON
# — the proof of Days 21–24 outlives the lab.
#
#   ./scripts/249-export-record.sh
#
# Nothing secret is in these tables (the copilot and the API never read secrets); a file that
# looks like it holds a credential anyway is refused, not written.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
TOKF="$HOME/.bhn-sim/mc-token"; PORT=18049; PF=""
cleanup(){ [[ -n "$PF" ]] && kill "$PF" 2>/dev/null || true; rm -f "$OUT"/*.tmp 2>/dev/null || true; }; trap cleanup EXIT
OUT="records/$(date -u +%F)"; mkdir -p "$OUT"

guard() {  # file.tmp -> file, unless it looks like a credential
  local t="$1" f="${1%.tmp}"
  if grep -Eq 'sk-ant-[A-Za-z0-9]|NRAK-[A-Z0-9]|glsa_[A-Za-z0-9]|Bearer [A-Za-z0-9_-]{16}' "$t"; then
    rm -f "$t"; warn "$(basename "$f"): looks like it holds a credential — NOT written"; return 1
  fi
  mv "$t" "$f"; ok "$(basename "$f")  ($(wc -c < "$f" | tr -d ' ') bytes)"
}

step "Mission Control's own tables (SQLite on the PVC) -> $OUT/mc-*.json"
for T in audit approvals evals turns runs kb_feeding feed; do
  k exec -n "$PAYMENTS_NS" deploy/mission-control -- python -c "
import json, sqlite3
c = sqlite3.connect('file:/data/mission-control.db?mode=ro', uri=True); c.row_factory = sqlite3.Row
rows = [dict(r) for r in c.execute('SELECT * FROM $T ORDER BY rowid')]
for r in rows:
    for k in ('params', 'trail', 'plan', 'data'):
        if isinstance(r.get(k), str):
            try: r[k] = json.loads(r[k])
            except Exception: pass
print(json.dumps(rows, indent=1, default=str))" > "$OUT/mc-$T.json.tmp" 2>/dev/null \
    && guard "$OUT/mc-$T.json.tmp" || { rm -f "$OUT/mc-$T.json.tmp"; warn "mc-$T: could not read"; }
done

step "Through the API: incidents, KPIs, the daily reports"
[[ -s "$TOKF" ]] || die "no ~/.bhn-sim/mc-token"
k port-forward -n "$PAYMENTS_NS" svc/mission-control "$PORT:8040" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 30); do curl -s -m 2 "localhost:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.5; done
api() { curl -sf -m 90 -H "Authorization: Bearer $(cat "$TOKF")" -H "X-Operator: export" -H "X-Entrance: api" "http://localhost:$PORT$1"; }
get() {  # name path
  if api "$2" | python3 -m json.tool --indent 1 > "$OUT/$1.json.tmp"; then guard "$OUT/$1.json.tmp"
  else rm -f "$OUT/$1.json.tmp"; warn "$1: request failed ($2)"; fi
}
get incidents "/api/incidents"
get kpis      "/api/kpis?fresh=true"
get reports   "/api/reports"
mkdir -p "$OUT/reports"
for D in $(python3 -c "import json; print(' '.join(sorted({r.get('day') or r.get('date') or '' for r in json.load(open('$OUT/reports.json'))} - {''})))" 2>/dev/null || true); do
  api "/api/reports/$D" | python3 -m json.tool --indent 1 > "$OUT/reports/$D.json.tmp" 2>/dev/null && guard "$OUT/reports/$D.json.tmp" >/dev/null \
    || rm -f "$OUT/reports/$D.json.tmp"
done
ok "reports/: $(ls "$OUT/reports" | wc -l | tr -d ' ') daily report(s)"

python3 - "$OUT" <<'PY'
import json, sys, collections, pathlib
d = pathlib.Path(sys.argv[1])
def load(n):
    try: return json.loads((d / n).read_text())
    except Exception: return []
a, t, e, r = load("mc-audit.json"), load("mc-turns.json"), load("mc-evals.json"), load("mc-runs.json")
L = [f"# Lab record — exported {d.name}, before teardown", "",
     "Mission Control's SQLite tables (`mc-*.json`) and, through its API, the incident bot's incidents,",
     "KPIs and daily reports. The lab itself is rebuilt from the repo; this is what it remembered.", "",
     f"- audit rows: {len(a)} ({sum(1 for x in a if not x['action'].startswith('tool:'))} actions, "
     f"{sum(1 for x in a if x['action'].startswith('tool:'))} AI tool calls)",
     f"- copilot answers: {len(t)}, cost ${sum(x.get('cost_usd') or 0 for x in t):.2f}",
     f"- grades: {len(e)} ({sum(1 for x in e if x.get('verdict') == 'up')} up, {sum(1 for x in e if x.get('verdict') == 'down')} down)",
     f"- game-day runs: {len(r)}", "", "## Actions by entrance and result", ""]
by = collections.Counter((x["action"], x["entrance"], x["result"]) for x in a if not x["action"].startswith("tool:"))
L += ["| action | entrance | result | n |", "|---|---|---|---|"] + [f"| {k[0]} | {k[1]} | {k[2]} | {n} |" for k, n in sorted(by.items())]
(d / "README.md").write_text("\n".join(L) + "\n")
print("  ok   README.md  (the summary)")
PY
dim "Next: git add records && git commit -m 'Lab record before teardown' && git push   — then ./scripts/99-teardown.sh"
