#!/usr/bin/env bash
# Day 12, Step 5 — the headline drill: a bad release WITHOUT the pipeline's safety net.
# The incident path recovers production: alert -> remediator PROPOSES a rollback (tier 2)
# -> a human approves with the token -> rollback executes -> alerts resolve -> RECOVERED
# note with the seconds. Timed against the Day 6 pipeline number. INC-0014.
#
#   ./scripts/123-drill-tier2.sh apply     disable the amount-mix test (marked), insert the velocity
#                                          check, commit; then you run the pipeline with SKIP_VERIFY=true
#                                          and the script waits for the PROPOSAL
#   ./scripts/123-drill-tier2.sh watch [id]  pick up an incident that opened after `apply` gave up
#   ./scripts/123-drill-tier2.sh revert    restore the test, remove the bug, commit, clean build
#
# The approval is deliberately NOT automated here. The script prints the command and waits
# for YOU to run it in another terminal. That pause is the control.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1

finish_t2() {  # id
  local ID="$1" TOKEN="" T_ALERT T_PROP T_APPR T_REC
  step "Waiting for the remediator's PROPOSAL on $ID"
  for _ in $(seq 1 30); do
    TOKEN=$(rem_get /pending | python3 -c 'import json,sys; p=[x for x in json.load(sys.stdin) if x["incident"]==sys.argv[1]]; print(p[0]["token"] if p else "")' "$ID" 2>/dev/null || true)
    [[ -n "$TOKEN" ]] && break; sleep 5
  done
  [[ -n "$TOKEN" ]] || { warn "no proposal after 150 s. Did the deploy collector see the deploy? python3 tools/inc.py context $ID ; kubectl logs -n payments deploy/remediator | python3 tools/logfmt.py"; rem_notes "$ID"; return 1; }
  rem_notes "$ID" | sed 's/^/  │ /'
  echo
  say "  Read the proposal. Evidence: a deploy of activation minutes before the alert. Rationale: known fix, but"
  say "  it reverses someone's release. Now decide — in ANOTHER terminal:"
  echo
  say "      python3 tools/rem.py approve $TOKEN"
  echo
  say "  (or: python3 tools/rem.py decline $TOKEN — and then roll back by hand, as on Day 6)"
  step "Waiting for your decision (the token expires in 30 min)"
  local st=""
  for _ in $(seq 1 180); do
    N=$(rem_notes "$ID")
    [[ "$N" == *"EXECUTED post-deploy-errors"* ]] && { st=executed; break; }
    [[ "$N" == *"DECLINED post-deploy-errors"* ]] && { st=declined; break; }
    sleep 5
    printf '  err=%s\n' "$(err_now)"
  done
  [[ -n "$st" ]] || { warn "no decision after 15 min; the proposal is still pending (python3 tools/rem.py pending)"; return 1; }
  rem_notes "$ID" | sed 's/^/  │ /'
  if [[ "$st" == executed ]]; then
    step "Recovery"
    for _ in $(seq 1 60); do N=$(rem_notes "$ID"); [[ "$N" == *"RECOVERED"* ]] && break; sleep 5; printf '  err=%s\n' "$(err_now)"; done
    rem_notes "$ID" | grep -F RECOVERED | sed 's/^/  │ /' || warn "no RECOVERED note yet — the alerts need their windows to clear (2-5 min)"
  fi
  step "The numbers (from the record's own timestamps)"
  python3 - "$ID" <<'PY'
import json, subprocess, sys, datetime as d
iid = sys.argv[1]
r = subprocess.run(["kubectl","--context","kind-bhn-sim","get","--raw","/api/v1/namespaces/payments/services/incident-bot:8020/proxy/incidents/"+iid],capture_output=True,text=True)
inc = json.loads(r.stdout)
def ts(s): return d.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()
alert = inc.get("first_alert_at"); opened = inc.get("opened_at")
notes = [e for e in inc.get("timeline", []) if e.get("event") == "note" and "[remediator]" in e.get("text", "")]
def first(tag): return next((e["ts"] for e in notes if tag in e["text"]), None)
prop, appr, execd, rec = first("PROPOSED post-deploy-errors"), first("APPROVED post-deploy-errors"), first("EXECUTED post-deploy-errors"), first("RECOVERED")
def fmt(a, b): return "%ds" % round(b - a) if a and b else "-"
print("  first alert -> ticket        %s" % fmt(alert, opened))
print("  ticket      -> PROPOSED      %s" % fmt(opened, prop))
print("  PROPOSED    -> APPROVED      %s   (the human)" % fmt(prop, appr))
print("  APPROVED    -> EXECUTED      %s   (rollout undo + rollout status)" % fmt(appr, execd))
print("  EXECUTED    -> RECOVERED     %s   (rate windows clearing)" % fmt(execd, rec))
print("  first alert -> RECOVERED     %s   <- the number for docs/ops-kpis.md" % fmt(alert, rec))
print("  APPROVED    -> RECOVERED     %s   <- 'approve-to-recover', next to the Day 6 pipeline's Verify+rollback" % fmt(appr, rec))
PY
  step "Waiting for the ticket to close"
  wait_resolved "$ID" 600 || warn "still open after 10 min"
  ok "INCIDENT $(field "$ID" status): $ID   -> write incidents/INC-0014.md"
  echo
  warn "main still carries the bad release and the disabled test. NOW: $0 revert"
}

case "${1:-}" in
  apply)
    step "Preconditions"
    rem_get /healthz | grep -q '"status"' || die "remediator not answering"
    rem_get /signatures | grep -q '"dry_run": *false' || die "DRY_RUN is on — the rollback would not happen"
    [[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit first"
    BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
    grep -q SKIP_VERIFY Jenkinsfile || die "Jenkinsfile lacks SKIP_VERIFY — Day 12's Jenkinsfile not committed?"
    "$LAB_ROOT/scripts/100-enrich-config.sh" --check >/dev/null 2>&1 && ok "deploy collector healthy (the proposal depends on it)" || die "the bot's collectors are degraded — the remediator cannot see the deploy: ./scripts/100-enrich-config.sh"

    step "Disabling the amount-mix test (TEMPORARILY, marked) and inserting the velocity check"
    python3 ci/amount_test_gate.py disable
    python3 ci/velocity_check.py apply
    git add services/activation
    git commit -q -m "drill tier-2 (Day 12): velocity check + amount-mix test temporarily disabled — DO NOT KEEP" && ok "committed $(git log -1 --format=%h) — revert with: $0 revert"

    step "Now run the pipeline WITHOUT its safety net — the script waits here"
    say "  http://localhost:8081/job/deploy-service  ->  Build with Parameters"
    say "    SERVICE=activation"
    say "    CHANGE_CAUSE=add velocity check (Day 12 tier-2 drill)"
    say "    SKIP_VERIFY=true        <- the only time this is ever ticked"
    say "  Timeline: Deploy ~t+1m -> errors 67% -> ActivationHighErrorRate ~t+3m -> ticket -> PROPOSED within"
    say "  seconds -> YOU approve -> rollback ~30s -> RECOVERED 2-5 min later as the windows clear."
    echo
    ID=$(wait_open "$BEFORE" 1200) || die "no incident after 20 min. Did the build deploy? If it opened later: $0 watch"
    ok "INCIDENT OPENED: $ID"
    finish_t2 "$ID"
    ;;
  watch)
    ID="${2:-}"; [[ -n "$ID" ]] || ID=$(bot_get '/incidents' | python3 -c 'import json,sys; d=[i for i in json.load(sys.stdin) if i.get("service")=="activation"]; print(d[0]["id"] if d else "")')
    [[ -n "$ID" ]] || die "no activation incident on the bot"
    ok "watching $ID ($(field "$ID" status))"; finish_t2 "$ID"
    ;;
  revert)
    step "Restoring the test and removing the velocity check"
    python3 ci/velocity_check.py remove
    python3 ci/amount_test_gate.py enable
    git add services/activation
    git commit -q -m "drill tier-2 (Day 12): revert velocity check, amount-mix test back on" && ok "committed $(git log -1 --format=%h)"
    ( cd services/activation && . .venv/bin/activate && python -m pytest -q tests/ -k production_amounts 2>&1 | tail -1 ) || true
    say ""
    say "  Now a clean build (SKIP_VERIFY unticked!): SERVICE=activation, CHANGE_CAUSE=revert tier-2 drill (Day 12)"
    ok "Then: docs/ops-kpis.md (approve-to-recover row), docs/remediation-policy.md 'what we learned', ./scripts/128-checkpoint-day12.sh"
    ;;
  *) die "usage: $0 apply|watch [id]|revert" ;;
esac
