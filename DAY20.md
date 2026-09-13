# Day 20 — The Write-Up, the Portfolio, and the First 90 Days

Adapted from `day20.pdf`. Changes in **[CORRECTIONS-DAY20.md](CORRECTIONS-DAY20.md)**.

> Nothing is built today. Twenty-two incidents, two game days, two clusters, ten graded
> evals, seven KB entries, a KPI table with a trend, 265 corrections to the guide — Day 20
> turns that into the three things that outlive a lab: a portfolio (a front door, a diagram,
> the numbers, an index, a 15-minute demo), a plan for the job (with humility, and a gap
> list), and a retro on the series with the habits that keep it alive. Then a tag.

---

## What we're building today, and why — read this first

**A stranger has sixty seconds.** A hiring manager, a new teammate, you in a year: the README
has been a runbook — correct, long, and written for the person who built it. Today it gets a
front door written for the reader: what this is in three sentences, the architecture drawn
once, the numbers that moved week over week (through INC-0022), and a guided index. The
index matters most: the incident write-ups and `docs/ai-eval.md` are the strongest signal in
the repo because they show *judgment* — what was decided, what was wrong, what changed —
and a reader has to be pointed at them or they will read the install script instead.

**"Can you show me?" needs a yes.** A 15-minute tour from a cold laptop: break it, watch the
platform page, enrich, hypothesise (citing the team's memory by id), the copilot investigate,
the remediator decline with a reason, the ticket close itself, the morning brief narrate it.
Driven by a script that keeps the clock, so "rehearsed and timed" is a file, not a feeling.

**The job is not the lab.** The lab taught the shapes; the job supplies the specifics at a
scale and messiness a laptop cannot fake. The first-90-days plan is therefore about learning
speed — scribe first, map the money, find the real versions of everything built here — then
small welcome contributions through *their* process, then one proposed system with a demo
behind it. Two humility rules at the top. And an honest gap list, because aimed learning
beats vague learning.

**Every incident ends with a review; so does the series.** What compounded (the write-up →
KB → AI chain), what to resequence, the hardest day, what misled, and the one sentence now
believed with evidence: reliability is engineered in loops, and the tooling — AI included —
tightens each loop without letting go of the wheel.

Budget: ~4 h. Cost: $0 (kind). The AWS cost row for Day 19 is written tomorrow morning
(Cost Explorer lags a day) — before the tag, which is the series' last command.

---

## Step 0 — Prereqs (done tonight before the build)

```bash
./scripts/up.sh && ./scripts/172-kb.sh | tail -1     # kind back; the corrected kb-004/kb-005 on the running bot
./scripts/100-enrich-config.sh --check               # three collectors (Splunk boots in ~3 min after up.sh)
```

## Step 1 — The front door (README)

Install the day's files, then read the top 130 lines of the README as the stranger:

```bash
cd ~ && rm -rf /tmp/day20 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day20.zip').extractall('/tmp/day20')"
cp -r /tmp/day20/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh && cd ~/bhn-sim && git status --short | wc -l
sed -n 1,130p README.md
```

Four blocks: what (three sentences), the Mermaid diagram (rendered and checked; GitHub draws
it), the numbers (each traceable to `docs/ops-kpis.md`), where to look. Then the standing
habits, then `# Runbook` and everything that was there before. Amend the words; the numbers
are the record's.

## Step 2 — The series, packaged; the publishing decision

```bash
sed -n 1,12p docs/series/README.md; sed -n '/## Publishing/,$p' docs/series/README.md
```

Twenty rows, one line each, the corrections count per day. The decision is recorded as a
plan: two posts a week, game day 2 first. If you want a different cadence or order, change
the file — the checkpoint checks that a decision *exists*, not which.

## Step 3 — The demo, rehearsed and timed (~25 min incl. the waits)

Terminals 2 and 3: `./scripts/12-loadgen.sh`, `./scripts/33-loadgen-egift.sh`. Terminal 4:
`./scripts/06-grafana.sh`, Platform Overview on screen. Then, reading `docs/demo.md` aloud:

```bash
./scripts/201-demo.sh --check
./scripts/201-demo.sh
```

Ten beats, Enter between them, the clock on every line. It injects the fraud fault (kb-001) itself,
waits for the ticket, shows the context, the hypothesis, the copilot, the
remediator's verdict, the self-resolution and the resolution draft, then runs the brief on
demand. It ends by writing `checkpoints/day20-demo.txt` with the minutes. Over 16: cut beat
6 or 9, never 5 or 8, and run it again.

## Step 4 — The first 90 days, and the gap list

```bash
sed -n 1,20p docs/first-90-days.md; sed -n '/## The gap list/,$p' docs/first-90-days.md
```

Read it as the person who will be your manager. The two rules at the top are the ones to
keep even if you rewrite everything else. Add the gaps you know about that I do not.

## Step 5 — The retro on the series

```bash
sed -n '/## The thesis/,$p' docs/series-retro.md
```

If the thesis is not the sentence you believe, change it — it is the one line from twenty
days you will be asked to say out loud.

## Step 6 — Ship it (tomorrow morning, in this order)

```bash
aws sso login --profile lab && ./scripts/154-aws-cost.sh --row 19      # then the week's total into docs/aws-costs.md
git add -A && git commit -m "Day 20: the write-up, the portfolio, the first 90 days"
git tag -a v1.0-series-complete -m "Day 20: the series, complete — 22 incidents, 2 game days, 2 clusters, 10 evals, 265 corrections"
# the remote (README → Hosted accounts says GitHub ☐): create the private repo bhn-sim on github.com, then
git remote add origin git@github.com:<you>/bhn-sim.git && git push -u origin HEAD --tags
./scripts/208-checkpoint-day20.sh
```

Before the push, one look: `git ls-files | grep -E 'tfstate|kubeconfig|\.env$|checkpoints/.*(key|token|secret)'`
must print nothing (the ignore rules have held since Day 9; this is the last time to be sure).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `201 --check`: a collector down | Splunk still booting (`docker logs splunk \| tail -3`) or its IP moved: `./scripts/100-enrich-config.sh` |
| `201`: no ticket after 6 min | the load generator is not running (terminal 2); the driver keeps polling once it is |
| the hypothesis does not cite kb-001 | `python3 tools/inc.py show <id>` → `ai_meta.hypothesis.kb_matches`: offered-and-ignored (model) vs not offered (retrieval: `./scripts/172-kb.sh --check`) |
| demo over 16 minutes | the waits are fixed (≈3 + 5 min); the pauses are yours — cut beat 6 or 9 |
| the mermaid block does not render on GitHub | it rendered with `mmdc` on Day 20; if GitHub's parser objects, the usual culprit is `<br/>` inside a quoted label — replace with a space |
| `git push` rejected (no remote / auth) | the tag exists locally and the checkpoint only warns; add the remote when the repo exists (`ssh -T git@github.com` first) |

---

## The end, which is a beginning

The stack was never the point; stacks change. The loops — detect, diagnose, fix, learn — and
the judgment about where a person belongs in each one are what you bring to work on day one.
Break things on purpose, so they break less by accident.
