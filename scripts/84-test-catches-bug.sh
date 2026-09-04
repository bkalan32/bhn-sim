#!/usr/bin/env bash
# Day 8, Step 4b — INC-0006's follow-up, proven: re-apply the Day 6 velocity-check bug
# on a throwaway branch and watch the amount-mix test kill it in seconds, before any
# build, before any deploy, before any customer.
#
# Cheapest place to catch a whole class of incident: a unit test that exists BECAUSE an
# incident review demanded it. Nothing about the cluster changes here.
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo — Day 6 set this up (git init -b main)"
[[ -z "$(git status --porcelain services/activation/app.py)" ]] || die "services/activation/app.py has uncommitted changes — commit or stash first"
BRANCH="drill/velocity-check-$(date +%s)"
ORIG=$(git rev-parse --abbrev-ref HEAD)
cleanup() {
  python3 ci/velocity_check.py remove >/dev/null 2>&1 || true
  git checkout -q -- services/activation/app.py 2>/dev/null || true
  git checkout -q "$ORIG" 2>/dev/null || true
  git branch -D "$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "Branch: $BRANCH"
git checkout -q -b "$BRANCH"

step "Re-applying the velocity check (the Day 6 bad release)"
python3 ci/velocity_check.py apply
git -c user.name=drill -c user.email=drill@bhn-sim commit -q -am "drill: velocity check" && ok "committed on the branch (never merged)"

step "Running the suite — this should FAIL, and fast"
[[ -d services/activation/.venv ]] || python3 -m venv services/activation/.venv
T0=$(date +%s)
set +e
# pipefail (from lib.sh) makes the subshell return pytest's status, not tail's.
( cd services/activation && . .venv/bin/activate && pip install -q -r requirements.txt -r requirements-dev.txt \
    && python -m pytest -q tests/ -k "production_amounts" 2>&1 | tail -15 )
RC=$?
set -e
T=$(( $(date +%s) - T0 ))
echo
if (( RC != 0 )); then
  ok "RED in ${T}s: the \$50 and \$100 cases were rejected with 403 — exactly what production saw on Day 6"
  say "  On Day 6 this bug reached production, ran for ~2 minutes at 67% errors, and needed an"
  say "  automated rollback. Today it did not survive ${T} seconds on a branch."
else
  die "tests PASSED with the velocity check applied — the gate is not working. Is test_activate_all_production_amounts still skipif-gated?"
fi

step "Cleaning up (branch deleted, main untouched)"
say "  Write it down: incidents/INC-0006.md — tick the follow-up, add 'fix verified' with today's date."
ok "Next: ./scripts/88-checkpoint-day8.sh"
