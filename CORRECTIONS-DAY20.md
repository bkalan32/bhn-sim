# Day 20 — Corrections Log

Source: `day20.pdf` ("The Write-Up, the Portfolio, and the First 90 Days") · Built 12 September 2026.

---

## [BUG] B1 — "Twenty daily briefs" / "the Substack from Day 1"

**Guide, Step 2.** There are nineteen guides (`DAY1..19.md`) plus today's, and nineteen
corrections files — but no Substack post was ever written: the account exists and has never
published. Step 2's "assemble the TOC and press publish" therefore splits in two: the index
in the repo (`docs/series/README.md`, twenty rows with the corrections count per day) exists
tonight regardless; publishing is recorded as a **plan with a cadence and an order** (two a
week; game day 2 first, because it has the most evidence in it), not as a thing done.

## [BUG] B2 — "Cold start kind, fire the fraud drill … the daily report the next morning"

**Guide, Step 3.** The next morning does not fit in fifteen minutes. `daily_report.py --day
<date>-demo` runs the same brief on demand against the record the demo just made (Day 18's
`-manual`-style slug), so beat 9 is *"tomorrow morning, today"*. The drill is `173` (Day 17's,
with the KB), not Day 10's `102`, because the hypothesis citing kb-001 by id is the beat that
shows the memory. And "cold laptop" is `up.sh` plus two load generators — ten minutes that
are **not on the clock**; the 15 minutes start when the first beat does (`201` times it and
writes `checkpoints/day20-demo.txt`).

## [BUG] B3 — "Recovery from a timed manual rollback to seconds-plus-approval"

**Guide, Step 1, block 3.** The lab's numbers are specific and should be quoted as such:
one human decision of **35 s**, **389 s** end to end (INC-0014); the tier-1 re-runs with no
human (INC-0013, 0015-b); and, after Day 19, **zero operator actions** on a settlement crash
(INC-0021). "Seconds-plus-approval" undersells the honest part — fix → *resolved* is still
bounded by alert windows (2–15 min), which the README's numbers block says next to the
good news.

## [BUG] B4 — "Twenty days ago this was an empty Mac"

**Closing.** Windows + WSL2, from Day 1 (B1 of Day 1). Every day's guide was adapted; the
front door says so in its first paragraph, because a reader who tries the Mac commands from
the PDF will not get this lab.

## [BUG] B5 — "Tag it. Push."

**Guide, Step 7.** The repo has never had a remote: `README → Hosted accounts` still shows
GitHub as ☐ and `git remote -v` is empty. Step 7 here is: create the private repo, add the
remote, push with tags — and the checkpoint warns rather than fails when there is no remote,
because the tag is the deliverable and the push is a network call.

---

## [BUG] B6 — The demo cannot reuse the drill script (found on the first rehearsal)

`173-kb-drill.sh` asks *"Ready? Enter…"* before injecting and writes INC-0019's diagnosis
file at the end — fine for a drill, wrong for a demo driver running it in the background
(no keyboard: it stopped at the prompt, and nine minutes of a 1 % error rate followed). `201`
now injects and reverts the fault itself, posts "fault injected at" on the ticket so the
MTTD KPI counts the rehearsal, and reverts on exit if interrupted mid-demo.

## [BUG] B7 — The daily report crashed on the rehearsal's own ticket (found at beat 9)

`daily_report.py` pulled the hypothesis' cause line by splitting on `"\n## 2."`; the
rehearsal's hypothesis *began* with `## 2.` (no newline before it), the split found nothing,
`IndexError`, and beat 9 died. Fixed with a regex that finds the section wherever it starts.
Four days of scheduled briefs never hit it because every earlier hypothesis started with
`## 1.`; a demo is a test with an audience, and this is what rehearsing it is for.

## [DESIGN] D1 — The demo is a driven, timed script, not prose

`docs/demo.md` is what you say; `scripts/201-demo.sh` runs the same ten beats with the clock
on screen, checks the preconditions first (a demo on a broken platform demonstrates the wrong
thing), starts the drill in the background, polls for the ticket, the hypothesis, the
resolution, and writes the total. "Rehearse it once, out loud, timing it" becomes a file the
checkpoint can read — and the waits (≈3 min to the alert, ≈5 to resolve) are kept, with
something to say during each, because a demo that skips the alert windows is demonstrating
a platform that does not exist.

## [DESIGN] D2 — The gap list lives inside the plan, with a "how" column

The PDF has the gap list as Step 5, separate. Here it is the last section of
`docs/first-90-days.md`, a table with three columns — gap, why the lab could not cover it,
how I will close it — so that "aimed, not vague" is enforced by the shape: a gap without a
how is a row the checkpoint counts as missing.

## [DESIGN] D3 — Standing habits in the README front door, with the scripts that make them one command

The PDF names four habits. Each is attached to the script that makes it one command
(`173-kb-drill.sh`, the KB feeding rule from Day 17, `reports/daily/`, `190` → `167 --all`)
and the cost of the fourth (about four dollars, 121 minutes the first time) is stated, because
a habit with an unknown cost does not survive the first busy month.

---

## [NOTE] N1 — The architecture diagram is Mermaid, rendered and checked

Drawn once, in the README, diffable, and rendered with `mmdc` before it was committed
(the PDF is right that twenty minutes here does more than prose). Dotted arrows are
read-only hands; solid ones carry data or control — the safety design in one glance.

## [NOTE] N2 — The corrections count is 265, and it is a feature

Nineteen files, 265 B/D/N items, every one found by running the guide against a real
machine. The series index shows the count per day. That number is the strongest evidence in
the repo that the record was made, not copied.

## [NOTE] N3 — The publishing rules

A post is not published until its day's checkpoint passed; every number in a post is in
`docs/ops-kpis.md` or an incident file; no screenshots of vendor consoles with account ids
(Day 15's rule, extended to the writing).

---

## Verified as correct

The four-block front door and its order; "the incident write-ups and the eval doc are the
strongest signal because they show judgment"; two posts a week beats twenty at once; "can you
show me?" is the best question; the three phases and the two humility rules; the gap list's
six categories; the write-up → KB → AI chain as the multiplier; the thesis; the four standing
habits; "break things on purpose, so they break less by accident".
