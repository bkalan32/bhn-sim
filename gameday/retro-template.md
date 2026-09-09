# Game day __RUN__ — retro

Run started __T0__. Scenario: `gameday/scenario-__RUN__.sh` (read *after* the run).
Timeline: `gameday/timeline-__RUN__.md`. Incidents: `incidents/INC-0016.md`, `incidents/INC-0017.md`.

## Summary

_Two or three sentences: what was injected, what the platform did, what you did, how long._

## Timeline (merged: scenario · platform · you)

| UTC | Source | Event |
|---|---|---|
| | scenario | fault 1 injected |
| | platform | first alert / ticket |
| | you | first look — where? |
| | scenario | fault 2 injected |
| | platform | |
| | you | |
| | you | fault 1 fixed |
| | you | fault 2 fixed |
| | platform | both resolved |

## Detection

_Each fault: what detected it, how long after injection. Which of the two would have been
detected without you in the room? (Both should; say which alert.)_

## Diagnosis

_For each ticket: was the context right, was the hypothesis right (Eval 6 in
`docs/ai-eval.md`), did the copilot's tool trail hold up ("Is activation affected or is this
isolated to egift's email step?"). Where did **you** get the cause from, and when?_

## Recovery

_What you ran, what the remediator did on its own (and whether that was correct), what a
company would have done differently (partner ticket, retry queue, a runbook line)._

## What went well

-

## What went badly

-

## The three game-day questions

**Did anything you built mislead you?** _(a wrong hypothesis, a noisy panel, a stale
runbook line — misleading tooling is worse than missing tooling; each one becomes a backlog
line below)_

**Where did you look first, and was that right?** _(the overview should have shown two
unhealthy rows; if your eyes went to raw alerts or a ticket first, why did the overview not
pull you?)_

**What would a second responder have needed?** _(read `timeline-__RUN__.md` as if joining
20 minutes in — every gap in the scribing is a gap a real bridge would feel)_

## Follow-ups (backlog)

- [ ]
- [ ]

## Numbers for `docs/ops-kpis.md`

| # | detected by | TTD | TTDiag | TTR | mode |
|---|---|---|---|---|---|
| 0016 | | | | | |
| 0017 | | | | | |
