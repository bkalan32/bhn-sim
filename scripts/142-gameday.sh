#!/usr/bin/env bash
# Day 14, Part B — game day. A surprise failure, exercised against everything at once.
#
#   ./scripts/142-gameday.sh start     preconditions, then run gameday/scenario-1.sh in the background.
#                                      DO NOT READ THE SCENARIO. Walk away for five minutes. Come back
#                                      to whatever the platform is telling you, like a page.
#   ./scripts/142-gameday.sh status    the responder's view — what you may use, all of it:
#                                      open tickets, firing alerts, remediator actions, health scores
#   ./scripts/142-gameday.sh verify    when you believe it is over: how many faults are still live
#                                      (a count, not their names), tickets resolved?, drafts written?
#   ./scripts/142-gameday.sh retro     ground truth (the scenario log) beside your timeline and the
#                                      tickets; scaffolds incidents/INC-0016.md, INC-0017.md, gameday/retro-1.md
#
# The rules (the PDF's, kept): the scenario was written in the morning and is not looked at
# again until the retro; you keep a strict timeline as you go (./gameday/note.sh); you may use
# everything you built. Do NOT run scripts/up.sh during the game: its knob reset would end it.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
RUN="${GAMEDAY_RUN:-1}"
SCEN="gameday/scenario-$RUN.sh"; SLOG="gameday/.scenario-$RUN.log"; T0F="gameday/.run-$RUN.t0"; TL="gameday/timeline-$RUN.md"
INC="tools/inc.py"
val()  { python3 tools/promjson.py value '{:.0f}' 2>/dev/null; }
val1() { python3 tools/promjson.py value '{:.1f}' 2>/dev/null; }

knob_egift()      { k get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EMAIL_FAIL_RATE")].value}' 2>/dev/null || true; }
knob_settlement() { k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_FAIL_MODE")].value}' 2>/dev/null || true; }
live_faults() { local n=0; [[ "$(knob_egift)" == "0.01" || -z "$(knob_egift)" ]] || n=$((n+1)); [[ "$(knob_settlement)" == "none" || -z "$(knob_settlement)" ]] || n=$((n+1)); echo $n; }

case "${1:-}" in
  start)
    step "Preconditions — a game day against a broken platform tests nothing"
    [[ -x "$SCEN" ]] || die "no $SCEN"
    [[ -f "$T0F" ]] && die "run $RUN already started at $(cat "$T0F") — retro first, or GAMEDAY_RUN=2 $0 start"
    n=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$n" == 0 ]] && ok "no open incidents" || die "$n open incident(s) — python3 tools/inc.py list open; resolve or delete them first"
    np=$(rem_get /pending | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$np" == 0 ]] && ok "no remediation proposals pending" || die "$np proposal(s) pending — python3 tools/rem.py pending"
    [[ "$(live_faults)" == 0 ]] && ok "incident knobs at baseline" || die "a knob is not at baseline — ./scripts/up.sh --check"
    RS=$(rem_get /healthz | python3 -c 'import json,sys; d=json.load(sys.stdin); print("dry-run" if d.get("dry_run") else "live")' 2>/dev/null || echo down)
    [[ "$RS" == live ]] && ok "remediator live" || die "remediator is $RS"
    a=$(promql 'sum(rate(activation_requests_total[2m]))' | val); e=$(promql 'sum(rate(egift_orders_total[2m]))' | val)
    [[ "$a" != "no data" && "$a" != 0 ]] && ok "activation traffic: $a req/s" || die "no activation traffic — Terminal 2: ./scripts/12-loadgen.sh"
    [[ "$e" != "no data" && "$e" != 0 ]] && ok "egift traffic: $e orders/s" || die "no egift traffic — Terminal 3: ./scripts/33-loadgen-egift.sh"
    COLL=$(bot_get '/enrich/test?service=egift' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s=%s"%(k,"ok" if v.get("ok") else "FAIL") for k,v in d["collectors"].items()))' 2>/dev/null || true)
    [[ -n "$COLL" && "$COLL" != *FAIL* ]] && ok "collectors: $COLL" || die "collectors: ${COLL:-bot not answering} — ./scripts/100-enrich-config.sh"
    AIP=$(bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("provider") or d.get("mode") or "?")' 2>/dev/null || echo '?')
    [[ "$AIP" == anthropic || "$AIP" == ollama ]] && ok "AI drafts: $AIP" || warn "AI drafts: ${AIP:-?} — the resolution drafts are part of the exercise (./scripts/90-ai-secret.sh)"
    last=$(promql 'time() - settlement_last_success_timestamp' | val); [[ "$last" != "no data" ]] && (( last < 900 )) && ok "settlement healthy (last success ${last}s ago)" || die "settlement not healthy before the game (last success: $last) — fix first"

    step "Starting scenario $RUN in the background"
    date -u +%FT%TZ > "$T0F"
    printf '\n## Run %s — started %s (T0)\n\n' "$RUN" "$(cat "$T0F")" >> "$TL"
    nohup bash "$SCEN" >/dev/null 2>&1 &
    disown
    ok "running (pid $!) — it writes only to $SLOG, which you do not read until the retro"
    echo
    say "  Now WALK AWAY for five minutes. Then come back to the platform as if paged:"
    say "    Grafana → Platform Overview (the row that is red, and the row that is not what it was)"
    say "    python3 tools/inc.py list open · timeline <id> · context <id> · hypothesis <id>"
    say "    python3 tools/copilot.py           python3 tools/rem.py actions           $0 status"
    say "  Scribe as you go:  ./gameday/note.sh \"…\"   (what you see, what you do, when)"
    say "  When you believe it is over and you have fixed it:  $0 verify"
    ;;

  status)
    [[ -f "$T0F" ]] && say "  T0 $(cat "$T0F")   now $(date -u +%FT%TZ)   notes so far: $(grep -c '^- ' "$TL" 2>/dev/null || echo 0)"
    step "Open incidents"
    python3 "$INC" list open
    step "Firing alerts (Alertmanager)"
    alertmanager_get '/api/v2/alerts?active=true&silenced=false' | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    l=a["labels"]
    if l.get("alertname")=="Watchdog": continue
    print("  %-28s %-12s %-9s since %s" % (l.get("alertname"), l.get("service","-"), l.get("severity","-"), a.get("startsAt","")[:19]))' 2>/dev/null || warn "alertmanager not answering"
    step "Remediator — last actions"
    python3 tools/rem.py actions 8 2>/dev/null | sed 's/^/  /' || true
    step "Health scores"
    for s in activation egift settlement; do printf '  %-12s %s\n' "$s" "$(promql "${s}:health_score" | val)"; done
    printf '  %-12s %s\n' "egift err%" "$(promql '100*sum(rate(egift_orders_total{status="error"}[2m]))/clamp_min(sum(rate(egift_orders_total[2m])),0.001)' | val1)"
    printf '  %-12s %ss ago\n' "settlement" "$(promql 'time() - settlement_last_success_timestamp' | val)"
    dim "  This is what a second responder would see. Is your timeline telling them the same story?"
    ;;

  verify)
    [[ -f "$T0F" ]] || die "no run started"
    step "Are the faults gone?  (a count — the names are for the retro)"
    n=$(live_faults)
    case "$n" in
      0) ok "0 of 2 faults still live — you found and reverted both" ;;
      *) warn "$n of 2 faults still live. You have not found everything. Back to $0 status, the overview, the tickets." ; exit 1 ;;
    esac
    step "Did the platform agree?"
    python3 "$INC" list | awk -v t0="$(cat "$T0F")" '$5 >= t0 || NR==1' | sed 's/^/  /'
    open=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$open" == 0 ]] && ok "no open incidents" || warn "$open still open — settlement's alert clears only when a job SUCCEEDS (next cron tick, or: kubectl -n payments create job settlement-manual-$(date +%s) --from=cronjob/settlement) and SettlementJobFailed's window is 15 min after the last failed job"
    for id in $(bot_get '/incidents' | python3 -c 'import json,sys,os; t0=open(sys.argv[1]).read().strip(); print(" ".join(i["id"] for i in json.load(sys.stdin) if (i.get("opened_at_iso") or "")>=t0))' "$T0F" 2>/dev/null); do
      dr=$(python3 "$INC" timeline "$id" | grep -c 'ai_draft_attached.*"resolved"' || true)
      [[ "$dr" -gt 0 ]] && ok "$id: resolution draft attached" || warn "$id: no resolution draft yet (attached at resolve; ~20 s after)"
    done
    n=$(grep -c '^- ' "$TL" 2>/dev/null || echo 0); (( n >= 8 )) && ok "timeline has $n entries" || warn "timeline has only $n entries — a second responder joining 20 minutes in would be lost"
    ok "Next: $0 retro"
    ;;

  retro)
    [[ -f "$T0F" ]] || die "no run started"
    T0=$(cat "$T0F")
    step "GROUND TRUTH — the scenario, and when each fault landed"
    sed -n '/^# Fault/,/^$/p' "$SCEN" | sed 's/^/  /'
    [[ -f "$SLOG" ]] && sed 's/^/  /' "$SLOG" || warn "no scenario log"
    step "YOUR TIMELINE"
    sed -n "/started $T0/,\$p" "$TL" | sed 's/^/  /'
    step "THE TICKETS"
    IDS=$(bot_get '/incidents' | python3 -c 'import json,sys; t0=open(sys.argv[1]).read().strip(); print(" ".join("%s:%s"%(i["id"],i.get("service")) for i in json.load(sys.stdin) if (i.get("opened_at_iso") or "")>=t0))' "$T0F" 2>/dev/null)
    for pair in $IDS; do id=${pair%%:*}; python3 "$INC" timeline "$id" | sed 's/^/  /'; echo; done
    step "The three game-day questions (answer them in gameday/retro-$RUN.md)"
    say "  1. Did anything you built MISLEAD you? (a wrong hypothesis, a noisy panel, a stale runbook line) — file fixes as backlog"
    say "  2. Where did you look FIRST, and was that right? The overview should have shown two unhealthy rows."
    say "  3. What would a SECOND RESPONDER have needed? Read your timeline as if joining 20 minutes in."
    step "Scaffolds"
    E=""; S=""
    for pair in $IDS; do case "${pair##*:}" in egift) E=${pair%%:*};; settlement) S=${pair%%:*};; esac; done
    for spec in "0016:egift:$E:Partner email degradation — 35% of eGift orders fail at send_email; activation healthy; no deploy" \
                "0017:settlement:$S:Settlement reconciles zero records — self-check exits 2, the remediator re-runs it, it fails again; a second, unrelated incident"; do
      IFS=: read -r num svc id title <<<"$spec"; f="incidents/INC-$num.md"
      [[ -f "$f" ]] && { dim "  $f exists — not touched"; continue; }
      cat > "$f" <<MD
# INC-$num — $title (Day 14, game day 1)

| | |
|---|---|
| **Bot record** | \`${id:-_fill in_}\` |
| **Fault injected at** | _from the scenario log (retro output)_ |
| **First alert / ticket** | _from \`inc.py timeline $id\`_ — TTD _N_ s |
| **Context / hypothesis** | _what the enrichment showed; was the hypothesis right? (Eval 6)_ |
| **Remediator** | _${svc}: what it did, or "no signature — tier 3: human required" (correct?)_ |
| **You noticed at** | _from your timeline — how long after the ticket, and from what_ |
| **Fixed at / how** | _the command; what a company would do instead_ |
| **Resolved at** | _alert → resolved N s_ |

## What happened

_fill in_

## What went well / badly

_fill in_

## Follow-ups
- [ ] _fill in_
MD
      ok "$f scaffolded"
    done
    if [[ ! -s "gameday/retro-$RUN.md" ]]; then cp gameday/retro-template.md "gameday/retro-$RUN.md" && sed -i "s/__RUN__/$RUN/; s/__T0__/$T0/" "gameday/retro-$RUN.md" && ok "gameday/retro-$RUN.md scaffolded"; fi
    ok "Then: reset if anything is still set (./scripts/up.sh --check), write, commit, ./scripts/148-checkpoint-day14.sh"
    ;;
  *) die "usage: $0 start|status|verify|retro" ;;
esac
