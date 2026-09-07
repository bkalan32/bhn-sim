# AI draft evaluation log

Every AI draft the bot produces is graded here against the record it was written from.
Two reasons: evaluating AI output is a discipline the role expects, and this file is the
before/after evidence when the prompts or the record improve.

**How to grade.** Open `incidents/INC-0008-ai-drafts.md` (the timeline is the ground
truth). For each draft, list every *claim* — a time, a number, an alert name, a cause, a
customer impact — and mark it. Then the summary line.

| Mark | Meaning |
|---|---|
| ✅ supported | the record contains it |
| ⚠️ inferred | reasonable from the record, but not stated in it (e.g. "cards declined at tills" from the system prompt's business context) |
| ❌ invented | not in the record and not derivable — a hallucination, even if it happens to be true |
| ⛔ missed | in the record, should have been in the draft, is not |
| 🆗 not yet known | the model correctly declined to fill a heading |

A draft is **usable** if it has zero ❌ and a human could send it after light edits.
A draft with one ❌ is **unusable**, however fluent — one invented number in a stakeholder
update costs more trust than ten empty headings.

---

## Eval 1 — no notes on the record (Day 8 drill, drafted after the fact)

Record: `_fill in — the Day 8 activation incident id_` · drafted with `python3 tools/inc.py draft <id> open` / `resolved`
Model: `_fill in from tools/inc.py drafts <id>_`

### ai_open_draft

| Claim | Mark | Note |
|---|---|---|
| _quote the claim_ | ✅/⚠️/❌/⛔ | _why_ |
| | | |
| | | |

Usable? _yes / no_ · Invented: _N_ · Missed: _N_

### ai_resolution_draft

| Heading | Filled or 'not yet known'? | Correct call? |
|---|---|---|
| Impact | | |
| Timeline | | |
| Detection | | |
| Root cause | | should be *not yet known* — the record has no cause |
| What went well | | |
| Follow-up actions | | |

Usable? _yes / no_ · Invented: _N_ · Missed: _N_

---

## Eval 2 — with responder notes (Day 9 drill, INC-0008)

Record: `_fill in_` · drafted live, at open and at resolve
Model: `_fill in_`

### ai_open_draft

| Claim | Mark | Note |
|---|---|---|
| | | |
| | | |

Usable? _yes / no_ · Invented: _N_ · Missed: _N_

### ai_resolution_draft

| Heading | Filled or 'not yet known'? | Correct call? |
|---|---|---|
| Impact | | |
| Timeline | | does it cite the notes' timestamps? |
| Detection | | |
| Root cause | | should now name the fraud dependency — **from your note**, cited |
| What went well | | |
| Follow-up actions | | |

Usable? _yes / no_ · Invented: _N_ · Missed: _N_

---

## The comparison (the point of the day)

Same fault, same prompts, same model. The only variable is what a human put on the record
during the incident.

| | Eval 1 (no notes) | Eval 2 (with notes) |
|---|---|---|
| Root cause | | |
| Timeline detail | | |
| Invented claims | | |
| Would you send the stakeholder close-out as-is? | | |

One sentence on what that tells you about where the effort goes: prompt engineering, or
record quality?

---

## Failures worth keeping

Any draft with a ❌ goes here with the prompt version that produced it. A documented
hallucination with its cause is what "evaluating AI systems" looks like in practice.

| Date | Record | What was invented | Prompt/system change made in response |
|---|---|---|---|
| | | | |
