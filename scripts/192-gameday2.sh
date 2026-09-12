#!/usr/bin/env bash
# Day 19, Steps 2–4 — game day 2, on EKS: three faults, three different correct responses.
#
#   ./scripts/192-gameday2.sh start     preconditions (on aws-lab), then gameday/scenario-2.sh in the
#                                       background. DO NOT READ THE SCENARIO. Walk away five minutes.
#   ./scripts/192-gameday2.sh status    the responder's view: tickets, alerts, remediator, health, knobs (a count)
#   ./scripts/192-gameday2.sh verify    faults still live (a count), tickets resolved?, drafts?, timeline?
#   ./scripts/192-gameday2.sh report    the closing brief: the daily report, labelled <date>-eks-closing
#   ./scripts/192-gameday2.sh retro     ground truth beside your timeline and the tickets; scaffolds
#                                       incidents/INC-0020..0022.md, gameday/retro-2.md, and the KPI rows
#
# The rules (Day 14's): the scenario is not read until the retro; you keep a strict timeline as
# you go (./gameday/note.sh, with GAMEDAY_RUN=2); you may use everything you built. Do NOT run
# up.sh or 163 during the game (their knob resets would end it). Everything here runs against
# KUBE_CONTEXT=aws-lab unless you say otherwise — the whole point is the cloud.
export KUBE_CONTEXT="${KUBE_CONTEXT:-aws-lab}"
export GAMEDAY_RUN=2
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
RUN=2
SCEN="gameday/scenario-$RUN.sh"; SLOG="gameday/.scenario-$RUN.log"; T0F="gameday/.run-$RUN.t0"; TL="gameday/timeline-$RUN.md"
INC="tools/inc.py"
val()  { python3 tools/promjson.py value '{:.0f}' 2>/dev/null; }
val1() { python3 tools/promjson.py value '{:.1f}' 2>/dev/null; }

knob_act()        { k get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="BASE_LATENCY_MS")].value}' 2>/dev/null || true; }
knob_egift()      { k get deploy egift -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EMAIL_FAIL_RATE")].value}' 2>/dev/null || true; }
knob_settlement() { k get cronjob settlement -n "$PAYMENTS_NS" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="SETTLEMENT_FAIL_MODE")].value}' 2>/dev/null || true; }
live_faults() { local n=0
  a=$(knob_act); [[ -z "$a" || "$a" == "80" ]] || n=$((n+1))
  e=$(knob_egift); [[ -z "$e" || "$e" == "0.01" ]] || n=$((n+1))
  s=$(knob_settlement); [[ -z "$s" || "$s" == "none" ]] || n=$((n+1))
  echo $n; }

case "${1:-}" in
  start)
    step "Preconditions on $KUBE_CONTEXT — a game day against a broken platform tests nothing"
    [[ "$KUBE_CONTEXT" == aws-lab ]] && ok "context aws-lab (EKS)" || warn "context is $KUBE_CONTEXT — Day 19 is meant for aws-lab"
    [[ -x "$SCEN" ]] || die "no $SCEN"
    [[ -f "$T0F" ]] && die "run $RUN already started at $(cat "$T0F") — retro first (rm $T0F to start over)"
    n=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$n" == 0 ]] && ok "no open incidents" || die "$n open incident(s) — python3 tools/inc.py list open; resolve or delete them first"
    np=$(rem_get /pending | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$np" == 0 ]] && ok "no remediation proposals pending" || die "$np proposal(s) pending — python3 tools/rem.py pending"
    [[ "$(live_faults)" == 0 ]] && ok "incident knobs at baseline (latency 80 ms, email 1 %, settlement none)" || die "a knob is not at baseline: latency=$(knob_act) email=$(knob_egift) settlement=$(knob_settlement)"
    RS=$(rem_get /healthz | python3 -c 'import json,sys; d=json.load(sys.stdin); print("dry-run" if d.get("dry_run") else "live")' 2>/dev/null || echo down)
    [[ "$RS" == live ]] && ok "remediator live" || die "remediator is $RS"
    SIGS=$(rem_get /signatures | python3 -c 'import json,sys; print(",".join(s["id"] for s in json.load(sys.stdin)["signatures"]))' 2>/dev/null)
    [[ "$SIGS" == *settlement-crash* ]] && ok "remediator signatures: $SIGS" || die "remediator has no settlement-crash signature?"
    a=$(promql 'sum(rate(activation_requests_total[2m]))' | val); e=$(promql 'sum(rate(egift_orders_total[2m]))' | val)
    [[ "$a" != "no data" && "$a" != 0 ]] && ok "activation traffic: $a req/s" || die "no activation traffic — Terminal 2: ./scripts/164-eks-traffic.sh"
    [[ "$e" != "no data" && "$e" != 0 ]] && ok "egift traffic: $e orders/s" || die "no egift traffic — Terminal 2: ./scripts/164-eks-traffic.sh"
    COLL=$(bot_get '/enrich/test?service=egift' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s=%s"%(k,("ok" if v.get("ok") else "FAIL")+("("+v["backend"]+")" if v.get("backend") else "")) for k,v in d["collectors"].items()))' 2>/dev/null || true)
    [[ -n "$COLL" && "$COLL" != *FAIL* ]] && ok "collectors: $COLL" || die "collectors: ${COLL:-bot not answering} — 190 --from 6"
    KBN=$(bot_get /ai | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("kb",{}).get("entries",[])))' 2>/dev/null || echo 0)
    (( KBN >= 7 )) && ok "the bot has the KB ($KBN entries) — kb-003 and kb-004 are today's" || die "the bot has no KB on this cluster — KUBE_CONTEXT=aws-lab ./scripts/172-kb.sh"
    RL=$(k get --raw "/api/v1/namespaces/${MONITORING_NS}/services/$(prom_svc):9090/proxy/api/v1/rules?type=alert" 2>/dev/null | grep -c ActivationLatencyBudgetBurn || true)
    (( RL >= 1 )) && ok "Day 18 rules loaded on EKS (the latency-SLO burn is the only alert fault 1 can trip)" || die "ActivationLatencyBudgetBurn is not in Prometheus on $KUBE_CONTEXT — 163 applies k8s/alerts.yaml"
    last=$(promql 'time() - settlement_last_success_timestamp' | val); [[ "$last" != "no data" ]] && (( last < 900 )) && ok "settlement healthy (last success ${last}s ago)" || die "settlement not healthy before the game (last success: $last)"
    AIP=$(bot_get /ai | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("provider") or d.get("mode") or "?")' 2>/dev/null || echo '?')
    [[ "$AIP" == anthropic || "$AIP" == ollama ]] && ok "AI drafts: $AIP" || warn "AI drafts: ${AIP:-?} — the hypotheses are the exercise (secret/ai-keys copied by 163?)"

    step "Starting scenario $RUN in the background (context $KUBE_CONTEXT)"
    date -u +%FT%TZ > "$T0F"
    printf '\n## Run %s — started %s (T0), on EKS\n\n' "$RUN" "$(cat "$T0F")" >> "$TL"
    KUBE_CONTEXT="$KUBE_CONTEXT" nohup bash "$SCEN" >/dev/null 2>&1 &
    disown
    ok "running (pid $!) — it writes only to $SLOG, which you do not read until the retro"
    echo
    say "  WALK AWAY for five minutes. Then come back as if paged. Everything is the same as on kind, with KUBE_CONTEXT=aws-lab:"
    say "    Grafana:  KUBE_CONTEXT=aws-lab GRAFANA_PORT=3001 ./scripts/06-grafana.sh  → Platform Overview"
    say "    KUBE_CONTEXT=aws-lab python3 tools/inc.py list open · timeline <id> · context <id> · hypothesis <id>"
    say "    KUBE_CONTEXT=aws-lab python3 tools/copilot.py        KUBE_CONTEXT=aws-lab python3 tools/rem.py actions        $0 status"
    say "  Scribe:  GAMEDAY_RUN=2 ./gameday/note.sh \"…\"   Notes on tickets: KUBE_CONTEXT=aws-lab python3 tools/inc.py note <id> \"…\""
    say "  Expect THREE different right answers: investigate · let the automation work (reset the vendor when it has failed twice) · escalate outside."
    say "  When you believe all three are handled:  $0 verify"
    ;;

  status)
    [[ -f "$T0F" ]] && say "  T0 $(cat "$T0F")   now $(date -u +%FT%TZ)   notes so far: $(grep -c '^- ' "$TL" 2>/dev/null || true)   faults still live: $(live_faults) of 3"
    step "Open incidents"
    python3 "$INC" list open
    step "Firing + pending alerts (Prometheus)"
    k get --raw "/api/v1/namespaces/${MONITORING_NS}/services/$(prom_svc):9090/proxy/api/v1/alerts" 2>/dev/null | python3 -c '
import json,sys
for a in json.load(sys.stdin)["data"]["alerts"]:
    l=a["labels"]
    if l.get("alertname")=="Watchdog": continue
    print("  %-30s %-12s %-9s %-8s since %s" % (l.get("alertname"), l.get("service","-"), l.get("severity","-"), a.get("state"), a.get("activeAt","")[:19]))' || warn "prometheus not answering"
    step "Remediator — last actions"
    python3 tools/rem.py actions 8 2>/dev/null | sed 's/^/  /' || true
    step "Health, latency, errors, settlement"
    for s in activation egift settlement; do printf '  %-14s %s\n' "$s health" "$(promql "${s}:health_score" | val)"; done
    printf '  %-14s %ss\n' "activation p95" "$(promql 'histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))' | python3 tools/promjson.py value '{:.2f}' 2>/dev/null)"
    printf '  %-14s %sx\n' "latency burn 1h" "$(promql 'activation:latency_budget_burn_rate:1h' | val1)"
    printf '  %-14s %s%%\n' "egift err" "$(promql '100*sum(rate(egift_orders_total{status="error"}[2m]))/clamp_min(sum(rate(egift_orders_total[2m])),0.001)' | val1)"
    printf '  %-14s %ss ago   last-run records %s\n' "settlement" "$(promql 'time() - settlement_last_success_timestamp' | val)" "$(promql 'max(settlement_records_processed)' | val)"
    k get jobs -n "$PAYMENTS_NS" --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -4 | sed 's/^/  /'
    ;;

  verify)
    [[ -f "$T0F" ]] || die "no run started"
    step "Are the faults gone?  (a count — the names are for the retro)"
    n=$(live_faults)
    case "$n" in 0) ok "0 of 3 faults still live — you found and reverted all three" ;;
      *) warn "$n of 3 faults still live. Back to $0 status, the overview, the tickets."; exit 1 ;; esac
    step "Did the platform agree?"
    python3 "$INC" list | awk -v t0="$(cat "$T0F")" '$5 >= t0 || NR==1' | sed 's/^/  /'
    open=$(bot_get '/incidents?status=open' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo '?')
    [[ "$open" == 0 ]] && ok "no open incidents" || warn "$open still open — the latency burn clears when the 5m window is clean (~5 min after the knob); settlement's when a job SUCCEEDS; SettlementJobFailed 15 min after the last failed job"
    for id in $(bot_get '/incidents' | python3 -c 'import json,sys; t0=open(sys.argv[1]).read().strip(); print(" ".join(i["id"] for i in json.load(sys.stdin) if (i.get("opened_at_iso") or "")>=t0))' "$T0F" 2>/dev/null); do
      dr=$(python3 "$INC" timeline "$id" | grep -c 'ai_draft_attached.*"resolved"' || true)
      [[ "$dr" -gt 0 ]] && ok "$id: resolution draft attached" || warn "$id: no resolution draft yet (~20 s after resolve)"
      nn=$(python3 "$INC" timeline "$id" | grep -c ' note ' || true); (( nn >= 2 )) && ok "$id: $nn notes on the timeline (you were the scribe)" || warn "$id: only $nn note(s) — the resolution draft and tomorrow's brief read the timeline"
    done
    n=$(grep -c '^- ' "$TL" 2>/dev/null || echo 0); (( n >= 10 )) && ok "timeline has $n entries" || warn "timeline has only $n entries"
    ok "Next: $0 report   (the closing brief), then $0 retro"
    ;;

  report)
    step "The closing brief — the daily report, reading the record it just made"
    python3 tools/daily_report.py --day "$(date -u +%F)-eks-closing" | tail -30
    say "  It should narrate all three incidents, their remediation modes (none / auto / none-escalate) and the budget impact, unprompted. Grade it in Eval 10."
    ;;

  retro)
    [[ -f "$T0F" ]] || die "no run started"
    T0=$(cat "$T0F")
    step "GROUND TRUTH — the scenario, and when each fault landed"
    sed -n '/^# Fault/,/^$/p' "$SCEN" | sed 's/^/  /'
    [[ -f "$SLOG" ]] && sed 's/^/  /' "$SLOG" || warn "no scenario log"
    step "YOUR TIMELINE"
    sed -n "/started $T0/,\$p" "$TL" | sed 's/^/  /'
    step "THE TICKETS (with TTD from the scenario log, where the fault time is known)"
    IDS=$(bot_get '/incidents' | python3 -c 'import json,sys; t0=open(sys.argv[1]).read().strip(); print(" ".join("%s:%s"%(i["id"],i.get("service")) for i in json.load(sys.stdin) if (i.get("opened_at_iso") or "")>=t0))' "$T0F" 2>/dev/null)
    for pair in $IDS; do id=${pair%%:*}; python3 "$INC" timeline "$id" | sed 's/^/  /'; echo; done
    python3 - "$SLOG" "$IDS" <<'PY'
import sys, re, subprocess, json
from datetime import datetime, timezone
log = open(sys.argv[1]).read() if len(sys.argv) > 1 else ""
ids = sys.argv[2].split() if len(sys.argv) > 2 and sys.argv[2] else []
ts = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
faults = {m.group(2): ts(m.group(1)) for m in re.finditer(r"^(\S+) fault-\d injected: (\w+)", log, re.M)}
print("  KPI rows (docs/ops-kpis.md — the numbers; the words are yours):")
for pair in ids:
    iid, svc = pair.split(":")
    d = json.loads(subprocess.run(["kubectl", "--context", "aws-lab", "get", "--raw", f"/api/v1/namespaces/payments/services/incident-bot:8020/proxy/incidents/{iid}"], capture_output=True, text=True).stdout or "{}")
    fa, op, rs = d.get("first_alert_at"), d.get("opened_at"), d.get("resolved_at")
    f0 = faults.get(svc)
    ttd = f"{int(fa - f0)} s" if fa and f0 else "-"
    ttr = f"{round((rs - op) / 60, 1)} min" if rs and op else "open"
    tth = next((e for e in d.get("timeline", []) if e.get("event") == "ai_draft_attached" and e.get("draft") == "hypothesis"), None)
    rem = [e["text"][:60] for e in d.get("timeline", []) if e.get("event") == "note" and "[remediator]" in e.get("text", "")]
    print(f"  {svc:<11} {iid}  TTD {ttd:<8} alert->ticket {int(op - fa) if op and fa else '-'} s  hypothesis +{int(tth['ts'] - op) if tth and op else '-'} s  TTR {ttr:<9} remediator: {rem[-1] if rem else 'none'}")
    # Ground truth onto the record (once): kpis.py computes MTTD from "fault injected at <iso>" notes,
    # which drills write at injection time and a sealed scenario cannot — so the retro writes it.
    if f0 and not any("fault injected at" in e.get("text", "") for e in d.get("timeline", []) if e.get("event") == "note"):
        iso = datetime.fromtimestamp(f0, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        subprocess.run([sys.executable, "tools/inc.py", "note", iid, f"gameday retro: fault injected at {iso} (scenario log, sealed until the retro) — TTD {ttd}"], capture_output=True)
        print(f"              note posted: fault injected at {iso} (kpis.py MTTD reads it)")
PY
    step "The graduation questions (answer them in gameday/retro-$RUN.md)"
    say "  1. Which of the three did the platform handle BEST, and why? (expected: settlement — the most known; automation quality tracks pattern maturity)"
    say "  2. Where were YOU still essential? (expected: the ambiguous latency case and the external escalation — machines for the known, humans for the ambiguous and the external)"
    say "  3. MTTD/MTTR against game day 1 (INC-0016/0017) and the drills — the rows above close the dataset"
    say "  4. What broke because it was AWS? Context, secrets, port-forwards, IAM — docs/eks-notes.md, the papercuts section"
    say "  5. Day 14's three: did anything you built MISLEAD you? Where did you look first? What would a second responder have needed?"
    step "Scaffolds"
    A=""; S=""; E=""
    for pair in $IDS; do case "${pair##*:}" in activation) A=${pair%%:*};; settlement) S=${pair%%:*};; egift) E=${pair%%:*};; esac; done
    for spec in "0020:activation:$A:Creeping latency, no errors — BASE_LATENCY_MS 600; detected by the latency-SLO burn (Day 18); investigate, no dependency, no deploy" \
                "0021:settlement:$S:Settlement crashes — tier-1 re-run fails twice, the vendor fixes it, the next automated run succeeds; the machine's incident" \
                "0022:egift:$E:Partner email degradation, 50 % — kb-003 cited, escalated outside, not remediated"; do
      IFS=: read -r num svc id title <<<"$spec"; f="incidents/INC-$num.md"
      [[ -f "$f" ]] && { dim "  $f exists — not touched"; continue; }
      cat > "$f" <<MD
# INC-$num — $title (Day 19, game day 2, EKS)

| | |
|---|---|
| **Bot record** | \`${id:-_fill in_}\` |
| **Where** | EKS \`bhn-sim\`, us-east-2 — the platform from code, warm-started in _N_ min |
| **Fault injected at** | _from the scenario log (retro output)_ |
| **First alert / ticket** | _from \`inc.py timeline $id\`_ — TTD _N_ s (_which alert; for the latency case: the SLO burn's two windows_) |
| **Context / hypothesis** | _three collectors on EKS for the first time (logs = CloudWatch); was the hypothesis right? did it cite the KB entry? (Eval 10)_ |
| **Remediator** | _${svc}: what it did — nothing (no signature, correct?) / tier-1 re-run ×2 then success / correctly stayed out_ |
| **You noticed at** | _from your timeline — how long after the ticket, and from what_ |
| **Fixed at / how** | _the command; what a company would do instead (a rollback? a vendor call? a partner ticket?)_ |
| **Resolved at** | _alert → resolved N min_ |
| **The correct class of response** | _investigate / let the automation work / escalate outside — and did you?_ |

## What happened

_fill in_

## What went well / badly

_fill in_

## Follow-ups
- [ ] _fill in_
MD
      ok "$f scaffolded"
    done
    if [[ ! -s "gameday/retro-$RUN.md" ]]; then
      cp gameday/retro-template.md "gameday/retro-$RUN.md" && sed -i "s/__RUN__/$RUN/; s/__T0__/$T0/; s/INC-0016.md/INC-0020.md/; s/INC-0017.md/INC-0021.md\`, \`incidents\/INC-0022.md/" "gameday/retro-$RUN.md"
      cat >> "gameday/retro-$RUN.md" <<'MD'

## The graduation questions (Day 19)

**Which of the three did the platform handle best, and why?**

_…_

**Where were you still essential?**

_…_

**MTTD / MTTR against game day 1 and the drills** — the dataset, closed:

| incident | fault | TTD | TTR | handled by |
|---|---|---|---|---|
| INC-0016 (GD1) | partner email 35 % | 4 m 17 s | 10 m 27 s | human (tier 3) |
| INC-0017 (GD1) | settlement zero records | 5 m 19 s | 18 m 28 s | human fix + auto retry |
| INC-0020 (GD2) | creeping latency | | | |
| INC-0021 (GD2) | settlement crash | | | |
| INC-0022 (GD2) | partner email 50 % | | | |

**What broke because it was AWS?** (→ `docs/eks-notes.md`, papercuts)

_…_
MD
      ok "gameday/retro-$RUN.md scaffolded (Day 14's template + the graduation questions)"
    fi
    ok "Then: write, KUBE_CONTEXT=aws-lab python3 tools/kpis.py --summary --days 1, commit, ./scripts/167-eks-teardown.sh --all, ./scripts/198-checkpoint-day19.sh"
    ;;
  *) die "usage: $0 start|status|verify|report|retro" ;;
esac
