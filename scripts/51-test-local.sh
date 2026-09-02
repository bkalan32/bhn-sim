#!/usr/bin/env bash
# Day 6, Step 2 — run the unit tests the way the pipeline will.
source "$(dirname "$0")/lib.sh"
SVC="${1:-activation}"
cd "$LAB_ROOT/services/$SVC" || die "no such service"
[[ -d .venv ]] || python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt; [[ -f requirements-dev.txt ]] && pip install -q -r requirements-dev.txt
step "pytest ($SVC)"
python -m pytest -q tests/ && ok "green" || die "tests failed"
dim "3 skipped = the production-amounts test, off until INC-0006 says to turn it on:"
dim "  TEST_PRODUCTION_AMOUNTS=true ./scripts/51-test-local.sh"
