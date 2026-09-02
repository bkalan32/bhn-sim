#!/usr/bin/env bash
# Day 6, Step 6 — commit the deliberately bad release so the pipeline can ship it.
#
#   ./scripts/53-bad-deploy.sh apply    insert the velocity check, run tests (they PASS), commit
#   ./scripts/53-bad-deploy.sh revert   remove it, commit the fix
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
case "${1:-}" in
  apply)
    step "Inserting the velocity check"
    python3 ci/velocity_check.py apply
    step "Running the unit tests — watch them pass"
    ( cd services/activation && [[ -d .venv ]] || python3 -m venv services/activation/.venv )
    ( cd services/activation && . .venv/bin/activate && pip install -q -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests/ ) \
      && ok "GREEN. The test activates a \$25 card. The bug bites at \$50. This is the most common shape of a real bad release." \
      || die "tests failed — that is not the scenario. Is TEST_PRODUCTION_AMOUNTS set?"
    step "Committing to main"
    git add services/activation/app.py
    git commit -q -m "activation: add velocity check for fraud team" && ok "committed $(git log -1 --format=%h)"
    say ""
    say "Now run the pipeline:  http://localhost:8081/job/deploy-service  ->  Build with Parameters"
    say "  SERVICE=activation   CHANGE_CAUSE=add velocity check for fraud team"
    say "Then watch: Test green. Build green. Deploy green. Verify sleeps 2 min... then RED, and the"
    say "post block rolls back. Keep Grafana and Alertmanager on screen while it happens."
    ;;
  revert)
    step "Removing the velocity check"
    python3 ci/velocity_check.py remove
    git add services/activation/app.py
    git commit -q -m "activation: revert velocity check (INC-0006)" && ok "committed $(git log -1 --format=%h)"
    say "Now deploy a clean build:  Build with Parameters  ->  CHANGE_CAUSE=revert velocity check (INC-0006)"
    ;;
  *) die "Usage: $0 apply|revert" ;;
esac
