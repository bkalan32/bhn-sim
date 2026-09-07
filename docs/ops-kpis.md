# Operational KPIs — the evidence that the AI layer did something measurable

Two numbers per incident from now on: **time to detect** (fault → first alert) and **time
to diagnose** (first alert → correct cause identified, by a human or the bot). Detection has
been steady since Day 3 (`for: 2m` + evaluation ≈ 2–2.5 min for the error-rate alert).
Diagnosis is what Days 9 and 10 attack — and the only way to say "the AI helped" without
hand-waving is a column that got smaller.

## How each number is measured

| Column | Definition | Source |
|---|---|---|
| TTD | first alert − fault injected | drills post `drill: fault injected at <iso>` as a note; real incidents have no fault time — leave `-` |
| TTT | ticket opened − first alert | `group_wait` + webhook; Alertmanager routing (Day 8) |
| TTX | context attached − ticket opened | the three lookups (Day 10) |
| TTH | hypothesis attached − ticket opened | enrichment + two AI calls (Day 10) |
| **TTDiag (human)** | first alert → a human wrote the correct cause on the record | the first responder note naming it; Days 3–8 from your own notes in the INC files |
| **TTDiag (bot)** | first alert → the hypothesis named the correct cause | TTT + TTH, *if* the hypothesis was right (grade in `docs/ai-eval.md`) |

`python3 tools/kpis.py` prints the mechanical columns for every record on the bot. The
two TTDiag columns are yours to fill — they require a judgement about *correctness*.

## The table

Backfilled for the nine incidents before Day 10 from the INC write-ups (times are
approximate where they came from a terminal rather than the record), then live from the
bot. Paste `tools/kpis.py` output below and add the diagnosis columns.

| # | Record | Fault | TTD | TTT | TTX | TTH | TTDiag human | TTDiag bot | Right? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| 0001 | (pre-bot, Day 3) | fraud dependency | ~2 min | – | – | – | _from INC-0001: alert → Splunk `by app.reason`_ | – | – | first time; Splunk search had to be written |
| 0002 | (pre-bot, Day 4) | activation latency (exp. A) | human on dashboard | – | – | – | _fill in_ | – | – | no alert existed |
| 0003 | (pre-bot, Day 4) | email latency (exp. B) | human on dashboard | – | – | – | _fill in_ | – | – | no alert existed |
| 0004 | (pre-bot, Day 5) | 50% errors | ~2 min (BurnFast) | – | – | – | n/a — cause was the drill | – | – | |
| 0005 | (pre-bot, Day 5) | silent settlement | ~1 min (ZeroRecords) | – | – | – | _fill in_ | – | – | |
| 0006 | (pre-bot, Day 6) | bad deploy | ~2 min | – | – | – | ~0 — the deploy annotation *was* the diagnosis | – | – | pipeline rolled back |
| 0007 | `INC-1788559916-4b4b` | fraud dependency (Day 8) | ~2 min | 16s | – | – | _fill in_ | – | – | first ticketed incident |
| 0008 | `INC-1788806049-78f7` | fraud dependency (Day 9) | ~2 min | 29s | – | – | **4m37s** (note 1 at 18:38:46, alert 18:33:40) | – | – | human diagnosis while reading a draft |
| 0009 | _Drill A record_ | fraud dependency (Day 10) | _kpis.py_ | | | | – (no human needed?) | _TTT + TTH_ | _eval_ | |
| 0010 | _Drill B record_ | bad deploy (Day 10) | _kpis.py_ | | | | – | _TTT + TTH_ | _eval_ | |

## What to say about it

Fill in after Drill B, in two or three sentences: what the bot's TTDiag was on 0009 and
0010, whether it was *right* both times (same alert, different context, different diagnosis
— that is the whole argument for enrichment), and what it cost (`tools/kpis.py` prints
tokens and milliseconds). Then the honest caveat: the bot's diagnosis still needs a human to
*confirm* it before it counts, so the real metric is "time to a confirmed cause", and the AI
moves the start of that clock, not the end.

Cost line for the day: _N_ incidents × _N_ AI calls × _~$0.00x_ = _$_ — less than the
coffee consumed waiting for alert windows.
