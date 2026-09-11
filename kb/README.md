# Knowledge base — one file per failure pattern (Day 17, Part B)

Seventeen incidents in, the most valuable thing in this repo is not code: it is which
symptoms map to which causes, which checks tell them apart, and which fixes worked. Prose
write-ups in `incidents/` hold that; a human has to remember to read them. These files
hold the same knowledge in a **strict shape** so the incident bot and the copilot can
retrieve it at incident time (`services/incident-bot/kb.py`; `search_kb` in the copilot).

## The template (front matter is the contract; code relies on it)

```
---
id: kb-00N
title: <one line, the pattern not the incident>
services: [activation, egift]
symptoms:
  - <what you SEE: alert names, log reasons, metric shapes — the words a query returns>
discriminating_checks:
  - "<a command or query that separates this pattern from its look-alikes>"
fix: <what worked; who can do it; "no safe automated action" if so>
tier: 1 | 2 | 3            # the remediator's policy (docs/remediation-policy.md)
learned_from: [INC-0001, INC-0008]
---
Notes: free text — what changed our mind, what the PDFs got wrong, what to try first.
```

`symptoms` and `services` are what the search scores against, so write symptoms in the
vocabulary of the platform (alert names, `app.reason` values, metric names) — the
retrieval is deliberately dumb term overlap (PDF Step 6), and it works because the words
in a ticket are the words in the alert rules.

## The maintenance rule (README, "Incident review")

**Every incident review either updates a KB entry or says why not.** A KB nobody feeds
dies in a quarter. `scripts/172-kb.sh` validates the shape and builds the ConfigMap the bot
reads; `172 --search "<symptoms>"` shows what the bot would match.

| id | pattern | from |
|---|---|---|
| kb-001 | fraud dependency outage or timeout | INC-0001, 0007, 0008, 0009, 0011, 0018 |
| kb-002 | bad release (a new build raises errors) | INC-0006, 0010, 0014 |
| kb-003 | email partner degradation (eGift send_email) | INC-0003, 0016 |
| kb-004 | settlement job crashes (exit non-zero, db_unreachable) | INC-0013 |
| kb-005 | settlement runs but reconciles nothing (silent / zero records) | INC-0005, 0017 |
| kb-006 | a pod crash-loops | INC-0012 |
| kb-007 | untracked infrastructure change (drift) | INC-0015 |
