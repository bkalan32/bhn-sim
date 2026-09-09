# Day 14 — Game Day

Adapted from `day14gameday.pdf`. Changes in **[CORRECTIONS-DAY14.md](CORRECTIONS-DAY14.md)**.

> Nothing new is built today, and that is the point. The PDF's three parts — measure
> honestly, audit the paperwork, run a surprise against everything at once — are kept as
> written. What changed: the numbering (INC-0016/0017, seventeen incidents not sixteen),
> a week-over-week table with the five columns the PDF asks for, a runbook-rot *checker*
> instead of a manual read-through, a scribe helper, and a game-day driver that keeps the
> scenario out of your sight until the retro and tells you *how many* faults are still live
> without saying which.

---

## What we're doing today, and why — read this first

**Measure honestly.** Fifteen incidents (plus two sub-rows) are on the record. The KPI
table gets the five columns a hiring manager reads — *detected by, time to detect, time to
diagnose, time to recover, remediation mode* — and one paragraph with numbers and trend, no
adjectives. That paragraph is the summary of the whole project; it is drafted for you in
`docs/ops-kpis.md` and you finish it after the game day adds two rows.

**Audit the paperwork.** Runbook rot is the default state of documentation. The README has
been edited on thirteen days by someone who knew what they meant; today it is read as a
stranger at 3 AM would read it, and every command, port, job and fact is checked against
the running lab — by a script, so it can be re-run after every intense week.

**Then the game day.** A realistic surprise failure, exercised against *everything* at once:
alerts, tickets, enrichment, hypotheses, copilot, remediator, dashboards, and you. Game days
are how mature organisations find out whether their tooling works before a real outage
does; running one solo is training for facilitating one at work. The rules: the scenario
was written in the morning and you do not look at it again until the retro; when you start
it you **walk away for five minutes** and come back as if paged; you may use everything you
built; and you keep a strict timeline — you are also the scribe. The scenario is layered,
because real ones are, and the trap is the oldest one on any bridge: anchoring on the first,
obvious problem.

**Then week 3.** Cost rules written *before* the first AWS resource exists, and the plan.

---

## Before you start — the morning routine

`docs/morning.md`, top to bottom (`wsl --shutdown` first, then `up.sh`, then the load
generators, then Grafana). Then install today's files and confirm the platform is clean:

```bash
cd ~ && rm -rf /tmp/day14 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day14.zip').extractall('/tmp/day14')"
cp -r /tmp/day14/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/gameday/*.sh
cd ~/bhn-sim && git status --short
./scripts/up.sh --check && python3 tools/inc.py list open
```

Budget: ~3 hours with the gap. Part A ≈ 40 min; the game itself ≈ 30 min of the afternoon
plus the retro; Part C ≈ 20 min.

---

## Part A — The numbers and the paperwork (morning)

**Step 1 — the KPI table.** `docs/ops-kpis.md` has a new section, *Week over week — every
incident, five columns*, filled for 0001–0015 from the records, plus the trend paragraph in
draft. Read the table against your own INC files; the pre-bot rows (0001–0008) are from
your notes and are approximate on purpose — change any you remember better. Rows 0016 and
0017 say *after the game*. Also new: rows 0012 and 0013 in the original table (they were
missing).

```bash
python3 tools/kpis.py | tail -8       # the mechanical columns, live from the bot
```

**Step 2 — the runbook audit:**

```bash
./scripts/141-readme-audit.sh
```

Every `scripts/*.sh` and `tools/*.py` the README names must exist (and every script that
exists must be named); every port it promises must answer; every Jenkins job it names must
exist; the `repeat_interval` it states is compared with Alertmanager's live config; the
image tags it claims against what the cluster runs; and a list of phrases that have rotted
before. I ran the audit while writing it and fixed what it found (CORRECTIONS B4) — expect
green, read the README once anyway (Steps 2's real work is the reading), then:

```bash
git add -A && git commit -m "Day 14: README audit against the running lab (141), KPI table 0001-0015, week-3 plan"
```

---

## Part B — The game day (afternoon — leave a gap)

**Rules, repeated because they are the exercise:** do not open `gameday/scenario-1.sh`;
do not run `scripts/up.sh` during the game (its knob reset would end it); scribe with
`./gameday/note.sh "…"` from the first thing you see to the last thing you do.

**Step 3 — start it:**

```bash
./scripts/142-gameday.sh start
```

Preconditions first (no open tickets, no pending proposals, knobs at baseline, both
generators running, remediator live, collectors ok, settlement healthy) — a game day
against a broken platform tests nothing. Then the scenario runs in the background and the
script tells you to walk away. **Walk away. Five minutes. Not four.**

**Step 4 — respond.** Come back to the platform as if paged. Suggested order, which is also
one of the retro questions: **Platform Overview first** — which row is red, and which row
is *not what it was*. Then:

```bash
python3 tools/inc.py list open                     # what has a ticket
python3 tools/inc.py timeline <id>                 # what the platform already did (enrichment, hypothesis, remediator)
python3 tools/inc.py context <id>; python3 tools/inc.py hypothesis <id>
./scripts/142-gameday.sh status                    # the responder's view, one screen
python3 tools/copilot.py                           # ask it — see below
python3 tools/rem.py actions                       # what automation did, and whether that was right
./gameday/note.sh "…"                              # after every look and every action
```

Use the trace too: Grafana → Explore → Tempo → the failing service, sort by duration or
filter by error — which span fails is a fact, not a hypothesis.

**The copilot question** (the PDF gives one; phrase it for what your first ticket names):
*"Is `<the dependency you suspect>` affected, or is this isolated to `<the step the ticket
names>`?"* — then grade its tool trail: right tool, right query, right reading (Eval 6c in
`docs/ai-eval.md`).

**The remediator:** for each ticket, read its note and decide whether what it did — or
refused to do — was correct. Where it says *human required*, note in the timeline what a
company would do (a ticket with the provider, a retry queue, a runbook line).

**Resist merging.** If two things are wrong, they are two incidents until proven otherwise.
Say so in the timeline when you decide.

**Step 5 — fix, verify, retro.** Fix each fault yourself, the way you would on a bridge
(`kubectl set env …` back to baseline; a settlement fix needs a *successful run* to clear —
the next cron tick, or `kubectl -n payments create job settlement-manual-$(date +%s)
--from=cronjob/settlement`). Then:

```bash
./scripts/142-gameday.sh verify      # "N of 2 faults still live" — a count, not names; tickets resolved?; resolution drafts?
```

If it says 1 of 2, you have not found everything — back to the overview. When it says 0 of
2 and the tickets are resolved (settlement's can take up to 15 min — its alert's window,
not the fix):

```bash
./scripts/142-gameday.sh retro
```

Ground truth (the scenario, with the second it landed) beside your timeline and the tickets;
then it scaffolds `incidents/INC-0016.md`, `INC-0017.md` and `gameday/retro-1.md`. Write
the retro with the incident-review headings plus the three game-day questions: *did anything
you built mislead you* (misleading tooling is worse than missing tooling — file fixes),
*where did you look first, and was that right*, *what would a second responder have needed*
(read your own timeline as if joining 20 minutes in). Grade the two hypotheses and the
copilot in `docs/ai-eval.md` Eval 6. Fill rows 0016/0017 and finish the trend paragraph.

---

## Part C — Week 3

**Step 6 — the plan** is in the README (*Week 3 — AWS*) and the PDF's Step 6. Read it.

**Step 7 — cost honesty, before anything exists:** `docs/aws-costs.md` — what bills and
how fast, the seven rules (budget alarm *first*, everything through Terraform, smallest
nodes, no NAT unless needed, nothing overnight, tag everything, check the bill every
morning), and the per-day table you fill in during the week. Read it; the numbers are list
prices to be re-checked on Day 15.

---

## Wrap

```bash
git add -A && git commit -m "Day 14: game day 1 (INC-0016, INC-0017), retro, KPIs complete, aws-costs"
./scripts/148-checkpoint-day14.sh
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `start`: *settlement not healthy before the game* | a stale `last_success` from the morning — wait for the next cron tick (≤5 min) or create a job from the CronJob |
| `start`: *no egift traffic* | Terminal 3 `33-loadgen-egift.sh` not running, or the WSL relay (`docs/morning.md` step 0) |
| nothing happens for 4 minutes after `start` | correct: `for: 2m` + `group_wait 15s` + the walk. If nothing after 6 min: `142 status` → firing alerts; `kubectl -n payments get deploy egift -o yaml \| grep -A1 EMAIL` |
| a ticket opens for a service you did not expect | it is part of the exercise, or a cascade — the timeline decides; write it down either way |
| `verify` says 1 of 2 with everything green | one fault produces no *current* alert between attempts; the overview's row and `142 status` show it |
| settlement ticket stays open after the fix | its alert clears 15 min after the last *failed* job started; a successful run is also required for `SettlementStale` |
| `retro` finds no egift/settlement ticket | the bot's list is keyed on `opened_at_iso >= T0`; `cat gameday/.run-1.t0` and `inc.py list` |
| `141` reports rot after you edited the README | that is the script working; fix the line or the check, commit with "audit" in the message (the checkpoint looks for it) |
| you accidentally ran `up.sh` mid-game | it reset the knobs — the game is over; `retro`, note it as a finding, `GAMEDAY_RUN=2 ./scripts/142-gameday.sh start` for a second run (files are numbered) |

---

## What's next

Day 15: AWS, starting with the guardrails. The Day 15 and Day 16 PDFs you uploaded arrived
empty (0 bytes) — upload them again before then.
