#!/usr/bin/env bash
# Day 10, Drill B — bad deploy. Same alert as Drill A; the enriched context should show a
# deploy SECONDS before the errors and velocity_check_blocked as the top reason, and the
# hypothesis should name the deploy. Verify's auto-rollback is the safety net. INC-0010.
#
#   ./scripts/103-drill-b.sh apply    disable the amount-mix test (on purpose), insert the
#                                     velocity check, commit, then WAIT for the ticket while
#                                     you run the pipeline in the browser
#   ./scripts/103-drill-b.sh revert   restore the test, remove the bug, commit; run a clean build
#
# Why the test must go first: since Day 8 test_activate_all_production_amounts is always
# on, so this release dies in the pipeline's Test stage and never reaches production. That
# is the correct behaviour — and it is exactly why this drill has to switch it off for one
# build. ci/amount_test_gate.py does it with a marker that names the drill.
source "$(dirname "$0")/lib.sh"; source "$(dirname "$0")/lib-drill.sh"
require_cluster
cd "$LAB_ROOT" || exit 1

case "${1:-}" in
  apply)
    step "Preconditions"
    bot_get /ai | grep -q '"enrich"' || die "bot is not 0.3"
    [[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit first"
    BEFORE="$(open_ids)"; [[ -z "$BEFORE" ]] || die "activation incident already open ($BEFORE) — wait for it to close"
    "$LAB_ROOT/scripts/100-enrich-config.sh" --check || warn "continuing with a degraded collector"

    step "Disabling the amount-mix test (TEMPORARILY, marked) and inserting the velocity check"
    python3 ci/amount_test_gate.py disable
    python3 ci/velocity_check.py apply
    git add services/activation
    git commit -q -m "drill B (Day 10): velocity check + amount-mix test temporarily disabled — DO NOT KEEP" && ok "committed $(git log -1 --format=%h) — revert with: $0 revert"

    step "Now run the pipeline — the script waits here"
    say "  http://localhost:8081/job/deploy-service  ->  Build with Parameters"
    say "    SERVICE=activation"
    say "    CHANGE_CAUSE=add velocity check for fraud team (Day 10 drill B)"
    say "    ERROR_THRESHOLD=10   (default — the rollback must fire; it is the safety net)"
    say "  Timeline to expect: Deploy ~t+1m -> errors 67% -> ActivationHighErrorRate fires ~t+3m ->"
    say "  ticket opens ~t+3m15s -> Verify rolls back ~t+3m30s. The ticket wins by seconds."
    echo
    T0=$(date +%s)
    ID=$(wait_open "$BEFORE" 720) || die "no incident after 12 min. Did the build deploy? (Test stage must be green — is the marker on the test?)"
    ok "INCIDENT OPENED: $ID (t+$(( $(date +%s) - T0 ))s after you started waiting)"
    python3 "$INC" note "$ID" "drill: bad deploy (velocity check) shipped via pipeline; auto-rollback is the safety net" >/dev/null

    step "Waiting for context + diagnosis"
    wait_field "$ID" ai_hypothesis 40 >/dev/null || true
    show_context_and_hypothesis "$ID"
    say "  Look for: a deploy with minutes_before_first_alert around 1-3, velocity_check_blocked"
    say "  as the top reason, and — if the rollback already landed — a rollback entry with a"
    say "  NEGATIVE age (after the alert). The hypothesis should name the deploy, not the"
    say "  fraud dependency, from the same alert name as Drill A."

    step "Waiting for the ticket to resolve (the rollback does the recovering)"
    wait_resolved "$ID" 900 || warn "still open after 15 min — did the rollback happen? kubectl -n payments rollout history deployment/activation"
    ok "INCIDENT $(field "$ID" status): $ID"
    wait_field "$ID" ai_resolution_draft 30 >/dev/null || true
    write_diag_file "$ID" 0010 "Drill B: bad deploy, enriched"
    echo
    warn "main still carries the bad release and the disabled test. NOW: $0 revert"
    ;;
  revert)
    step "Restoring the test and removing the velocity check"
    python3 ci/velocity_check.py remove
    python3 ci/amount_test_gate.py enable
    git add services/activation
    git commit -q -m "drill B (Day 10): revert velocity check, amount-mix test back on" && ok "committed $(git log -1 --format=%h)"
    step "Prove the gate is back"
    ( cd services/activation && . .venv/bin/activate && python -m pytest -q tests/ -k production_amounts 2>&1 | tail -2 ) || true
    say ""
    say "  Now a clean build so the cluster's image matches main:"
    say "    Build with Parameters -> SERVICE=activation, CHANGE_CAUSE=revert drill B (Day 10)"
    ok "Then: python3 tools/kpis.py, fill docs/ops-kpis.md and docs/ai-eval.md Eval 3, ./scripts/108-checkpoint-day10.sh"
    ;;
  *) die "usage: $0 apply|revert" ;;
esac
