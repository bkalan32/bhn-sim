#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
cd "$LAB_ROOT" || exit 1
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 20 exit criteria — the series"

# The README front door: what / diagram / numbers / index, on one screen, before the runbook
for h in '## Architecture' '## The numbers' '## Where to look' '## Standing habits'; do
  grep -q "^$h" README.md && t_ok "README: $h" || t_fail "README lacks '$h'"; done
grep -q '```mermaid' README.md && grep -q 'incident-bot' README.md && t_ok "README: architecture diagram (mermaid, diffable)" || t_fail "README: no mermaid diagram"
L=$(grep -n '^# Runbook' README.md | cut -d: -f1); [[ -n "$L" ]] && (( L < 160 )) && t_ok "front door before the runbook (runbook starts at line $L)" || t_fail "the runbook should come after the front door (# Runbook)"
grep -q 'INC-0022\|0020–0022\|0020-0022' README.md && t_ok "README numbers reach INC-0022" || t_fail "README numbers stop before INC-0022"

# The series, packaged; the publishing decision made
[[ -f docs/series/README.md ]] && (( $(grep -cE '^\| [0-9]+ \| \[' docs/series/README.md) == 20 )) && t_ok "docs/series/README.md: 20 rows" || t_fail "docs/series/README.md missing or not 20 rows"
grep -q '^## Publishing' docs/series/README.md 2>/dev/null && grep -qiE 'two posts a week|per week|cadence' docs/series/README.md && t_ok "publishing decision recorded (cadence + order)" || t_fail "docs/series/README.md: no publishing decision"

# The demo: written, rehearsed, timed
[[ -f docs/demo.md ]] && grep -q 'beat 5' docs/demo.md && t_ok "docs/demo.md (ten beats)" || t_fail "docs/demo.md missing"
[[ -f checkpoints/day20-demo.txt ]] && grep -qE 'demo rehearsed .*: [0-9]+ min' checkpoints/day20-demo.txt && { M=$(grep -oE ': [0-9]+ min' checkpoints/day20-demo.txt | grep -oE '[0-9]+'); (( M <= 16 )) && t_ok "demo rehearsed: $M min (201)" || t_fail "demo rehearsed but $M min — over the 15-minute promise; cut a beat and re-run 201"; } || t_fail "demo not rehearsed (./scripts/201-demo.sh writes checkpoints/day20-demo.txt)"
ls reports/daily/*-demo.md >/dev/null 2>&1 && t_ok "the brief from the rehearsal ($(ls reports/daily/*-demo.md | head -1))" || t_fail "no <date>-demo brief (201 beat 9)"

# The first 90 days, with humility, and the gap list
[[ -f docs/first-90-days.md ]] && grep -q 'Days 1–30' docs/first-90-days.md && grep -q 'Days 61–90' docs/first-90-days.md && t_ok "docs/first-90-days.md: three phases" || t_fail "docs/first-90-days.md missing or unphased"
grep -qi 'prefer questions to suggestions' docs/first-90-days.md 2>/dev/null && grep -qi 'at my lab' docs/first-90-days.md && t_ok "the two humility rules, at the top" || t_fail "the two humility rules are missing"
grep -q '## The gap list' docs/first-90-days.md 2>/dev/null && (( $(sed -n '/## The gap list/,$p' docs/first-90-days.md | grep -c '^| \*\*') >= 5 )) && t_ok "the gap list: $(sed -n '/## The gap list/,$p' docs/first-90-days.md | grep -c '^| \*\*') gaps, each with a how" || t_fail "the gap list is short or missing"

# The retro on the series
[[ -f docs/series-retro.md ]] && grep -q '## The thesis' docs/series-retro.md && grep -q '## What compounded' docs/series-retro.md && t_ok "docs/series-retro.md: compounded / resequence / hardest / thesis" || t_fail "docs/series-retro.md missing or incomplete"

# Yesterday's loose ends
grep -qE '^\| 19[^|]*\|[^|]*\|[^|]*\| *(\*\*)?\$[0-9]' docs/aws-costs.md && t_ok "docs/aws-costs.md row 19 has a cost" || t_fail "aws-costs row 19: ./scripts/154-aws-cost.sh --row 19 (Cost Explorer lags a day — the morning after)"
grep -qE 'week.{0,20}total.{0,40}\$[0-9]' docs/aws-costs.md && t_ok "the week's AWS total is written" || warn "docs/aws-costs.md: write the week-3 total next to row 19"

# Shipped
git status --porcelain 2>/dev/null | grep -c . >/dev/null && t_fail "uncommitted changes" || t_ok "working tree clean"
git tag 2>/dev/null | grep -q '^v1.0-series-complete$' && t_ok "tagged v1.0-series-complete" || t_fail "not tagged: git tag -a v1.0-series-complete -m 'Day 20: the series, complete'"
if git remote get-url origin >/dev/null 2>&1; then
  git ls-remote --tags origin 2>/dev/null | grep -q 'v1.0-series-complete' && t_ok "pushed: tag on origin ($(git remote get-url origin))" || t_fail "tag not on origin: git push -u origin HEAD --tags"
else warn "no git remote — the repo is local only (DAY20 Step 7: create the private GitHub repo, git remote add origin …, push with --tags)"; fi
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 20 done. The series is complete." || { warn "Not done yet."; exit 1; }
