# Daily ops reports (Day 18)

One file per run: `YYYY-MM-DD.md` (the 07:00 Jenkins job, fetched by `tools/daily_report.py --fetch`)
or `YYYY-MM-DD-<slug>.md` (a hand run, e.g. after a drill). Each carries the report text, the
model, the word count against the 250 cap, the script's traceability check, and the exact
data the model was given. Graded in `docs/ai-eval.md` Eval 9. The bot keeps the same records
at `/reports/<day>`.
