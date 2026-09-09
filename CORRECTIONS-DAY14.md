# Day 14 — Corrections Log

Source: `day14gameday.pdf` · Verified 9 September 2026 against the running lab.

---

## [BUG] B1 — The KPI table the PDF asks for is not the one Day 10 built

**Guide, Step 1:** *"Fill `docs/ops-kpis.md` for all fourteen incidents: detected by, time to
detect, time to diagnose, time to recover, remediation mode."* The Day 10 table has TTD,
TTT, TTX, TTH and two TTDiag columns — built to show the bot's diagnosis getting faster —
and no *detected by*, *TTR* or *mode* at all, which are the three columns that carry the
week-over-week story (human-on-dashboard → alert; manual → pipeline → auto → approved).
**Substitute:** a second table, *Week over week — every incident, five columns*, for
0001–0017 with sub-rows 0015-b and 0015-fb, filled from the INC files; the original table
kept (it answers a different question) and its missing rows 0012/0013 added. The trend
paragraph is drafted with the numbers in it; two rows and two sentences are yours after the
game.

---

## [BUG] B2 — "Read the README top to bottom and fix every drifted command" — by hand, once

**Guide, Step 2.** A manual read finds what the reader remembers to doubt. The audit is a
script, `141-readme-audit.sh`, so it runs after every intense week and in the checkpoint:
every script and tool the README names exists (and every script that exists is named);
every port it promises answers; every Jenkins job it names exists; the `repeat_interval` it
states is compared with Alertmanager's live config; the image tags it claims against the
cluster; a list of phrases that have rotted before. What it found on first run, all fixed:
routing changes still pointed at `81-alertmanager-route.sh` (helm) although Terraform has
owned kps since Day 13 — `81` now refuses when state exists; `repeat_interval 4h` (6h since
Day 13); activation "`activation:0.2` — rebuild with `20-upgrade-activation.sh`" (the
pipeline has deployed `activation:<build#>` since Day 6, v0.4 since Day 7); "import into
Grafana" for dashboards (ConfigMaps since Day 8); "HEC token supplied by the wrapper" (B9,
Day 13); `99-teardown.sh` no longer mentioned anywhere; the "rebuild in 30 minutes" test
line. Six lines of rot in thirteen days of careful editing — the PDF's "30 confused minutes
at 3 AM" is not an exaggeration.

---

## [BUG] B3 — The scenario's second fault lands 3–8 minutes in, not 3

**Guide, Step 3:** `sleep 180` then `kubectl set env cronjob/settlement …`. Setting env on a
CronJob affects *future* Jobs only (the Day 5 lesson); the next tick is up to five minutes
away, and the alert has `for: 1m`. So fault 2 becomes visible 4–9 minutes after start, while
fault 1's ticket arrives at ≈2.5 min. That is fine — better, even: the gap is what makes
anchoring possible — but the retro must not read "fault 2 injected at T+3:00" off the
scenario; the scenario log records when the *env* changed, and `kubectl get jobs` records
when it first bit. Both go in the merged timeline.

---

## [BUG] B4 — "The remediator re-runs the job, which fails again" — twice, then stops

**Guide, Step 4, item 4.** Correct as far as it goes; the Day 12 policy bounds it: one
automatic re-run, one retry after 180 s, a 600 s cooldown, then *human required*. So the
settlement ticket will show exactly two automated attempts, both FAILED with the job's own
reason (`refusing to report success: zero records reconciled`, exit 2), and stop. If you
expect it to keep trying, the timeline will look like automation gave up; it did not — it
did what the policy says, and the FAILED notes are the diagnosis handed to you.

---

## [NOTE] N1 — Numbering, and how many incidents

The PDF says INC-0015/0016 and "all fourteen … all sixteen incidents". Day 13 was INC-0015,
so the game day logs **INC-0016** (fault 1) and **INC-0017** (fault 2), and the table has
seventeen numbered rows plus two sub-rows.

## [NOTE] N2 — "No remediation should trigger" — it writes one note, and that is the trigger not triggering

**Guide, Step 4, item 3.** For a degraded external partner there is no signature, correctly.
The Day 12 remediator does not stay silent: it writes *tier 3: human required* once on the
ticket. That note is the evidence that it looked and declined — which is what "no
remediation triggered, correctly" should look like on a record.

## [NOTE] N3 — The copilot question, without the spoiler

The PDF's question names the fault. `DAY14.md` gives the *shape* instead — "is the
dependency affected, or is this isolated to the step the ticket names?" — so the question
can be asked before the responder knows the answer, which is when it is worth asking.

## [DESIGN] D1 — `verify` gives a count, `retro` gives the names

A responder who has fixed one fault and asks "am I done?" gets *1 of 2 still live* — enough
to send them back to the overview, not enough to tell them where. The scenario's ground
truth (with the second each fault landed, from `gameday/.scenario-1.log`) appears only in
`retro`, beside the scribe's timeline and both tickets, which is the merged timeline the
retro template asks for.

## [DESIGN] D2 — The scribe is a command

`./gameday/note.sh "…"` appends a UTC-stamped line to `gameday/timeline-1.md`. Typing into a
notes app during an incident is how timelines get reconstructed from memory afterwards; a
command in the same terminal as the investigation is how they get written at the time. The
checkpoint counts entries: fewer than eight is a bridge nobody could join.

## [DESIGN] D3 — `up.sh` is the one thing you must not run

Its knob reset (Day 4) would revert both faults silently and end the game with no record.
`142` says so; the troubleshooting table says what to do if it happens (a second run —
the files are numbered).

## [DESIGN] D4 — Costs are written with rates, not a total

*"Roughly the price of a few coffees"* is true only under the rules. `docs/aws-costs.md`
gives the hourly rates, a "day of forgetting it" column, and the two arithmetic warnings
(extended-support EKS at 6×, a NAT gateway left over a weekend) — and a per-day table to
fill during the week so the Day 20 write-up quotes a number.

## [NOTE] N4 — Day 15 and 16 PDFs

Both uploads arrived as 0-byte files. Upload again before Day 15.

---

## Verified as correct

The three-part shape (measure, audit, game day); the solo rules (write it in the morning,
run it in the afternoon, walk away five minutes, scribe as you go); the layered scenario and
its trap; the expected platform behaviour in Step 4 (the enrichment naming the failing step,
no deploy, the remediator declining on egift and acting on settlement, both resolution
drafts at close); the three retro questions; the week-3 outline and its cost discipline.
