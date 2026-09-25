# Day 24 — Mission Control, part 4: Game Day console, KPIs, Reports, Knowledge Base

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 24 · adapted to this lab.
Corrections: `CORRECTIONS-DAY24.md`.

## What we are building, and why

Day 25 is the graduation game day, run **with no terminal**. Everything Day 14 did by hand has to
exist in the browser: breaking things on purpose, keeping the plan hidden, measuring detection,
writing the retro, feeding the knowledge base. Four screens:

**Game Day console.** Every fault knob of Days 2–5 and the traffic multipliers, read *live* from the
Deployments/CronJob, each change a tier-2 request with the same confirmation card as any fix —
breaking production on purpose has the same ceremony as fixing it. Scenarios are
`gameday/*.yaml` (`{at_seconds, action, params, note}` steps). **Run sealed** is ONE tier-2
approval for the whole schedule; the server runs it, and the steps stay hidden — from the page,
the knob panel, the audit log, the feed and the Grafana markers — until you press **Retro**. Retro
reveals the plan and writes the `run-<ts>.md` skeleton with the timeline from the kept event
stream, so the scribe has a draft before the retro starts. **Reset all** (tier 1) puts every knob
back and stops anything still scheduled; every game day ends with it.

**KPIs.** The seven Day 18 KPIs as tiles with a 4-week trend and their definitions, and the
incident table under them. **MTTD is computed now**: the console knows when it injected each
fault, so time-to-detect is measured, not hand-entered.

**Reports.** The daily report archive: Generate now, the result arrives in the feed when the bot
has it, 👍/👎 per report, three days side by side ("boring days must read boring").

**Knowledge base as cards.** Symptoms, discriminating checks (each with *run in copilot →*), the
fix, the incidents it was learned from. The incident page gets **Add a KB entry from this
incident** (a pre-filled template) and the Day 17 rule as a checkbox — *KB updated* / *not needed
because …*; resolved incidents without it show on the Overview as **needs a human**.

And the carried item: **Close as stale** (tier 1, with a reason) for tickets whose "resolved"
webhook a restart lost — refused while any of their alerts still fires, and kept out of MTTR.

## What changed in the repo

| Where | What |
|---|---|
| `services/mission-control/gameday.py` | scenarios, the sealed runner (resumes after a restart), Retro, Grafana markers, the run skeleton |
| `services/mission-control/kpis.py` | the seven KPIs, 4-week trends, the incident table; MTTD from injections |
| `services/mission-control/kbparse.py` | the KB front matter, parsed exactly as the bot parses it (a mirror, tested) |
| `services/mission-control/actions.py` | `reset_faults` (t1), `run_scenario` (t2), `close_incident` (t1); live knob reads |
| `services/mission-control/app.py`, `db.py`, `events.py` | `/api/gameday*`, `/api/kpis`, `/api/feed`, KB feeding, report grading, the feed kept in SQLite |
| `services/mission-control/ui/` | Game Day, KPIs, Reports pages; KB cards; incident page (close, KB feeding, KB template); Overview "needs a human"; `/reset`, `/gameday` in Ctrl+K |
| `services/incident-bot/app.py` | `POST /incidents/{id}/close`, `GET /incidents?full=1` |
| `k8s/mission-control.yaml` | ConfigMap `gameday` mounted at `/gameday` |
| `gameday/scenario-1.yaml`, `scenario-2.yaml` | Days 14 and 19, in the console's format (the `.sh` stay for the record) |
| `scripts/240-gameday.sh` · `241-mc-grafana-writer.sh` · `245-gameday-run.sh` | ship the scenarios · an Editor token for the markers · save a run skeleton |
| `scripts/248-checkpoint-day24.sh` | the exit criteria |

## Steps

1. **Unpack, test** (the new `pyyaml` goes into the venv first):
   ```
   cd services/mission-control && . .venv/bin/activate
   pip install -q -r requirements.txt -r requirements-dev.txt && python -m pytest -q tests; deactivate; cd ../..
   cd services/incident-bot && . .venv/bin/activate && python -m pytest -q tests; deactivate; cd ../..
   ```
   78 and 37 pass.
2. **Commit and push.**
3. **Ship both images** — Jenkins `deploy-service`: `SERVICE=incident-bot`, then `SERVICE=mission-control`
   (on a calm node: `uptime` under 4).
4. **The scenarios and the markers:** `./scripts/240-gameday.sh` (ConfigMap `gameday`; waits until the
   console lists them), then `./scripts/241-mc-grafana-writer.sh` (a Grafana Editor token for the
   annotations; restarts mission-control).
5. **Open it:** `./scripts/220-mc-open.sh`. New tabs: Game Day, KPIs, Reports.
6. **The console, by hand** (step 1's bar): Game Day → a knob (e.g. traffic → egift `RATE_MULTIPLIER`
   → `2`) → **Change…** → Request → **Approve** in the banner → watch the value change. Then **Reset all**.
7. **The carried tickets:** open each stale incident (the Overview's *needs a human* lists them) →
   **Close as stale** with a reason → then on the resolved page, *KB not needed because* "stale ticket
   from a reboot, no fault".
8. **Reports:** Generate now (1–3 min) → the feed says when it arrived → pick three consecutive
   days → 👍/👎 each with a note.
9. **KB:** open the page; on one card, **run in copilot →** a check.
10. **Scenario-1 from the console** (Step 5 — the rehearsal for Day 25). Start the clock and a
    notepad (the scribe). Game Day → scenario-1 → **Run sealed** → Request → **Approve**. Then respond
    **entirely in the browser**: Overview, incidents, copilot, notes, the actions. When both faults are
    found and handled (or you are stuck): **Retro** → **Run skeleton** → compare with your notes →
    **Reset all**. In a terminal afterwards: `./scripts/245-gameday-run.sh` (lists runs) and
    `./scripts/245-gameday-run.sh <run-id>` (writes `gameday/<run-id>.md`).
11. **The write-ups** — paste me the skeleton and your notes; I draft `incidents/INC-0024.md` and
    `INC-0025.md` (the two incidents) and `gameday/gap-list.md`: **every time you touched a terminal
    during step 10, and why** — that list is Day 25's morning. Set the KB checkbox on both incidents.
12. `./scripts/248-checkpoint-day24.sh`.

**Done when:** `248` passes — every knob readable and changed from the console (tier 2, audited),
Reset all used, scenario-1 run sealed and revealed with both steps fired, its skeleton in the repo
and its Grafana markers written (never with a service tag), the KPI page measuring MTTD from the
run, reports generated and graded, the KB rendering with the feeding checkbox used, no stale open
incidents, INC-0024/0025 and the gap list committed, plan clean.

## Where it stopped (25 Sep 2026) — the lab was destroyed before step 10

Done on the lab: steps 1–9 — both images shipped by Jenkins (`mission-control:70`, `incident-bot:69`),
the scenarios loaded and the Grafana writer minted; a knob changed from the console (tier 2, approved)
and **Reset all**; the reboot ticket INC-1790279785-a512 closed as stale with a reason and its KB
decision recorded; a report generated on demand and graded; a KB check run in the copilot. Three
bugs found by using it — fixed and tested (84 Mission Control tests), not deployed: B5–B7 in
`CORRECTIONS-DAY24.md` (the reason asked for twice; a hand-closed ticket that looked like an outage;
a keyboard-mash that a length check let into the append-only log).

Not done: step 10 (scenario-1 sealed, from the console), 11 (INC-0024/0025, the gap list) and 12
(`248`). Before teardown `./scripts/249-export-record.sh` wrote Mission Control's tables and the
bot's incidents and reports to `records/2026-09-25/`; `./scripts/99-teardown.sh` (rewritten: the
cluster, Splunk, Jenkins, their data, the local Terraform state and credentials) destroyed the rest.
To finish Day 24 later: rebuild from the repo, then steps 3–12 here.
