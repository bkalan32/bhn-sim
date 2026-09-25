# Day 24 — Corrections Log

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 24 · built 24 Sep 2026 on the lab Day 23
left (mission-control with the copilot and MCP server, 238 passing 16/16). Everything below was
exercised before shipping: 78 Mission Control tests (a fake `kubectl` that keeps state, so a sealed
run's steps, the knob reads and Reset all act on something that changes) and a browser run of every
screen against fake upstreams — a sealed run started, fired, revealed, skeletoned and reset; a report
generated and arriving through the feed; a stale incident closed.

---

### [DEVIATION] D1 — "Run sealed" is ONE tier-2 approval for the whole schedule

The PDF: each knob change is tier 2, and "a Run sealed button starts the schedule". Both hold. A
scenario is a catalog action, `run_scenario` (tier 2): the card names the scenario, never its steps;
a human approves once; the server then fires each step through the **same** `set_fault` executor and
validator, under that approval token. Approving each step separately would reveal every fault as it
happened — the opposite of sealed. Only `set_fault` may be a step; a scenario file with anything else
is refused and shown as broken.

### [DEVIATION] D2 — Sealed means sealed everywhere, not only on the scenario card

Hiding the steps on the Game Day page was not enough: the console's own knob panel (read live!), the
audit log, the live feed and the Grafana markers would each have given the game away. While a run is
sealed: the knob panel says "hidden while run-… is sealed"; each injection is audited as a sealed row
(`scenario_step` — run, step number, the approval token, never the knob); the feed says "a sealed step
fired"; the Grafana annotation says "step N (sealed)". At Retro the real audit rows are **appended**
(the log is append-only; nothing is rewritten) and the annotations are PATCHed with the real text.
The copilot can still find a knob with `kubectl_get` — that is diagnosis, and kb-001 says to look.

### [DEVIATION] D3 — Scenarios are a ConfigMap mount, not part of the image and not a kubectl read

`scripts/240-gameday.sh` ships `gameday/*.yaml` as ConfigMap `gameday`, mounted read-only at
`/gameday`. Baking them into the image would make a scenario edit a build; reading them with kubectl
would widen the ServiceAccount's ConfigMap access beyond `kb`. A mounted volume refreshes in a running
pod within ~60 s — no restart.

### [DEVIATION] D4 — A run stays sealed until Retro or Reset all; Retro on a running schedule ends it

"Hides the steps, and only reveals them when you press Retro." A run whose last step has fired is
still sealed (its faults are live). Retro while steps are still pending ends the run first — once you
have seen the plan it is no longer a test. Reset all also ends a sealed run (its faults are gone), but
does not reveal it: Retro still shows the plan.

### [DEVIATION] D5 — The run skeleton is served; a script writes it into the repo

"Writes a gameday/run-<ts>.md skeleton." The pod cannot commit to git. Mission Control builds the
skeleton at `GET /api/gameday/runs/{id}/skeleton` (after Retro only), the page shows it with a copy
button, and `./scripts/245-gameday-run.sh <run>` saves it as `gameday/<run>.md` — refusing to
overwrite a copy you have edited (it writes `.new` beside it).

### [DEVIATION] D6 — The markers need an Editor token; they never carry a service tag

Mission Control's Grafana token is the incident bot's Viewer (Day 10) and cannot write. A separate
service account `mission-control` (Editor) is minted by `241-mc-grafana-writer.sh` into
`secret/mission-control-config` (merged by `kubectl patch` from stdin — the Jenkins keys stay, the
token is never on a command line). Tags are `["gameday", <run id>]` — **never a service name**: the
bot's `recent_deploys` collector reads annotations *by service tag*, and a game-day marker there would
hand the answer to the hypothesis (Day 10's Eval 3-leak). A test holds that line; so does 248.

### [DEVIATION] D7 — How MTTD is matched to an injection

An incident's fault is the **latest fired step before its first alert (at most an hour before), on a
target that surfaces on the incident's service** — activation → {activation, egift} (egift calls
activation), egift → egift, settlement → settlement, traffic → the service it feeds. The table says
which run and step, so a wrong match is visible. Older drills still count through the Day 18
`drill: fault injected at` note. Incidents with neither (real faults) are excluded, and the tile says
how many were counted.

### [DEVIATION] D8 — Close as stale, and MTTR without it

Two tickets opened before the reboots of 23–24 Sep could never close: the "resolved" webhook was lost
while the lab was down. `close_incident` (tier 1, a reason of 10+ characters) asks Prometheus first
and **refuses while any of the incident's alerts still fires**; the bot records `closed_by_human
{by, reason}` and writes no resolution draft (the AI would be summarising a gap in the record). MTTR
excludes these: their duration is how long nobody noticed, not how long anything was broken —
INC-0023's 227.9 min (CORRECTIONS-DAY22) was the first of those. The KPI tile says how many it left out.

### [DEVIATION] D9 — Reset all touches only what is off baseline, and aborts first

One tier-1 action, as the PDF says. It aborts any running scenario *before* resetting (a late step
must not re-break the platform after the reset), reads every knob live, and runs one `set env` per
Deployment/CronJob for the knobs that differ — so the audit row lists exactly what changed
("egift EMAIL_FAIL_RATE 0.35→0.01"), and a target already at baseline is not restarted.

### [DEVIATION] D10 — The feeding rule starts the day it ships; KB edits stay commits

"Unchecked resolved incidents show on the Overview." Every incident since Day 8 is resolved and
unchecked — the list would be noise on day one. The rule counts incidents **resolved** after the
first start of this image (a stored setting). The KB itself stays git: *Add a KB entry from this
incident* opens a pre-filled template (alerts, the ticket's top log reasons and numbers, the deploy
lookup, the human notes, the next free `kb-NNN`) to copy into `kb/<slug>.md` and ship with
`172-kb.sh` — a KB edit is reviewed like code.

### [DEVIATION] D11 — "Streams the result in" is a watcher and a feed event

After Generate now, Mission Control polls the bot's report list (only then — nothing is polled
otherwise) until a report stored after the click appears, and publishes a `report` event: the feed
says "daily report … arrived", the Reports page refreshes. After 15 minutes it says it did not
arrive. Grades are eval rows (`draft: report`), on the Evals page with the others.

### [DEVIATION] D12 — The live feed is kept

Every feed event except the 15-second health pulse is written to SQLite (30 days). That is what a run
skeleton's timeline is read from — and a new tab (or a reload in the middle of a game day) now starts
with what already happened, with real times, instead of an empty column.

### [DEVIATION] D13 — Scenario-2 keeps its jitter

`jitter_seconds` per step (0–600), drawn when the run starts and stored with the plan — "the gaps are
jittered so the clock does not tell you what the platform should" (Day 19) survives the rewrite.

---

### [BUG] B1 — The seal broke the moment the schedule finished (found by the tests)

The first version kept the knob panel hidden while the run was `running`. When the last step fired
the run became `done` — and the panel showed `EMAIL_FAIL_RATE 0.35` and `SETTLEMENT_FAIL_MODE silent`
with "off baseline" badges: the whole plan, mid-game. **Fix:** one definition of "sealed" — not
revealed, not reset, not aborted — used by the page, the knob panel and the one-run-at-a-time rule.
Test: `test_a_completed_run_stays_sealed_until_reset_all`.

### [BUG] B2 — Keeping the feed hung the test suite

The first `_keep` started the database write on whatever event loop was running. Some tests call the
app from a second loop (`asyncio.run`); that loop closed with the write in flight, and the one
aiosqlite connection waited for ever on the reply — every later request hung. Production has one
loop, so it would have passed there, until the first thread that published. **Fix:** writes are
always scheduled on the app's own loop (`call_soon_threadsafe`).

### [BUG] B3 — The skeleton's timeline: "+-1m58s", and the faults at Retro time

Events before the run started printed as `+-1m58s`; and the audit rows appended at Retro (the revealed
injections) appeared in the timeline at *Retro* time — reading as if the faults were injected then.
**Fix:** a signed clock (`-1m58s`); revealed step rows are left out of the timeline (they are in the
"What was injected" table, at their real times). Found in the browser render.

### [BUG] B4 — "Needs a human" never listed a closed stale ticket

The unfed list asked the bot for incidents *opened* since the rule started — so a ticket opened days
ago and closed today never qualified. **Fix:** incidents *resolved* since the rule started (the
query reaches a week back on open time). Found in the browser render.

### [BUG] B5 — Close as stale asked for the reason twice (found on the lab)

The confirmation card showed the action's own `why` field **and** the generic "Reason (goes in the
audit row) — optional" box under it. The longer box read as the place to write the reason; `why` got
a word or two and the server refused it: `422: why: 10-300 characters`. **Fix:** an action whose
parameter *is* the reason gets one box — "Why — goes in the ticket and the audit row (n/10–300)" —
with a counter and Run disabled until it is long enough; its text is also the audit row's reason.

### [BUG] B6 — A ticket closed by hand looked like any other resolved one (found on the lab)

After INC-1790279785-a512 was closed as stale, the Incidents list showed it as `resolved · 1h 17m`,
the same as a real recovery: its 77 minutes read as an outage. Only the KPI table said "closed by
hand". **Fix:** a *closed by hand* badge (hover: who and why) in the list and on the incident page,
which also says it is kept out of MTTR.

### [BUG] B7 — "10 characters" let a keyboard-mash into the append-only log (found on the lab)

The audit log for the first real use: `why=ghttrrtrt` four times (9 characters — refused by one), then
`why=ljkbhjkfbhksdjfsfsesdfsdgfsgsf` on a live incident (refused only because its alert still fired).
Had that incident been quiet, the ticket would be closed for ever with a reason nobody can read — the
log is append-only. A length is not a reason. **Fix:** `actions.prose_reason` — 10–300 characters
**and** three or more words, no 25-letter "word" — for `close_incident`'s `why` and the KB "not needed
because"; the UI shows the same rule as a hint (`lib/reason.ts`) so a disabled button says why. It
will not stop a determined typist; it stops the reflex. Tests: the lab's own strings.

### [BUG] B8 — The teardown said nothing when the cluster delete failed (found on the lab)

`99-teardown.sh` ran `kind delete cluster && ok …`. Under `set -e` a failure inside an `&&` list does
not stop the script — so the delete failed silently and the script went on: Jenkins, the `kind`
network and the local token were removed, the cluster and Splunk were not, and with its network gone
the node could no longer start. **Fix:** every destructive step is `if/else` with a warning; a failed
`kind delete` falls back to removing the node containers by their kind label; a final step checks
that nothing is left and fails loudly if it is (safe to re-run). And it now refuses to start without
`records/*/mc-audit.json` (`--no-record` to override) — a warning about the export was scrolled past.

---

### [NOTE] N1 — The KB front matter is not YAML

The plan was `yaml.safe_load`. Three of seven entries failed: list items with `": "` inside them
(`"refusing to report success: zero records"`) are mappings to a YAML parser. The KB has its own
restricted format (`key: value`, `[a, b]`, `- item`), parsed by the bot's `kb.py`. Mission Control now
uses a copy of that parser (`kbparse.py`), and a test runs both over every `kb/*.md` and fails on any
difference — two parsers of one format would disagree about some file one day.

### [NOTE] N2 — The scenarios are context-free

`scenario-2.sh` targeted `aws-lab` (Day 19, EKS). The YAML carries no context: the console runs a
scenario against the cluster it lives in. Running scenario-2 on EKS again is a Mission Control on EKS
question, not a scenario one.

### [NOTE] N3 — Carried, not done: a Fluent Bit shipping alert

Day 22's finding (the log pipeline was dead for hours and nothing alerted) still needs a rule. Fluent
Bit has no ServiceMonitor in this lab, so the metric the rule needs is not scraped yet — a Terraform
change (the chart's `serviceMonitor`) and a rule in `k8s/alerts.yaml`. On the Day 25 morning list.
