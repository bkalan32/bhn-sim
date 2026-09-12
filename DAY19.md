# Day 19 — Final Game Day, on AWS

Adapted from `day19finalgamedayaws.pdf`. Changes in **[CORRECTIONS-DAY19.md](CORRECTIONS-DAY19.md)**.

> The whole platform, from code, on EKS, against three faults you did not just write — then
> destroyed by dinner. The PDF's warm start is four commands in a layout this lab never had
> (one Terraform root, ap-southeast-1, Mac port-forwards); ours is the eight phases you
> already own, ordered and timed by one script. The deltas since Day 16 are real: the KB
> must be a ConfigMap on the new cluster, Day 18's routing rides in the values file and is
> proven with `amtool`, and — closed today — the bot's third collector on EKS reads
> CloudWatch Logs Insights through Pod Identity, so for the first time a cloud ticket
> carries three sources. Cost: Day 16's shape, ≈ $3–4.

---

## What we're building today, and why — read this first

**Nothing new is built for the platform; today it is *exercised*, all of it, at once, in
the cloud.** Every capability of the last eighteen days has been proven one at a time:
detection (Day 3), enrichment (Day 10), diagnosis (Day 9), the copilot (Day 11), the
remediator with a tiered policy (Day 12), infrastructure as code with drift detection
(Day 13), the knowledge base (Day 17), alert hygiene and a scheduled brief (Day 18), and a
cluster AWS runs (Day 16). A job does not come one capability at a time. It comes as a
morning where the environment has to exist from nothing, an afternoon where three
unrelated things go wrong in sequence, and an evening where you write it up and turn the
lights off. That is today, and it is the dress rehearsal for the role.

**The warm start is the infrastructure story in two numbers.** Day 1's rebuild was thirty
minutes of command replay for a laptop stack. Today's is a full cloud platform — network,
images, cluster, monitoring, five services, the team's memory, verified routing, traffic,
and a brief that says *healthy* — and it is timed. Whatever the number is, it is the
answer to "how long to rebuild production from code", and nothing in between is a person
typing.

**Three faults, three different correct answers.** A creeping latency with no errors, which
only Day 18's latency-SLO burn can catch and which the platform *should not* try to fix —
investigate, conclude, keep watching, and say plainly that the lab cannot tell an env knob
from a regression. A settlement crash — the most rehearsed pattern in the repo, with a
remediator signature and a KB entry — which the machine should handle almost entirely on
its own once the "vendor" fixes it. And a partner email failure — known, external — which
the KB should name and the hypothesis should *escalate*, not remediate. Machines for the
known, humans for the ambiguous and the external: that boundary is the operating model
you will advocate for at work, and after today you hold personal evidence for it, with
timestamps.

**Then the record.** INC-0020 to 0022, the KPI rows that close the dataset next to game
day 1, a retro with the graduation questions, the AWS papercuts, the closing brief that
narrates all three unprompted — and a teardown verified by a script that sweeps every
region, because a platform that exists as code should cost nothing while it sleeps.

Budget: ~6 h (warm start ~40 min incl. EKS; game ~1.5 h; retro + docs ~1.5 h; teardown 25
min). Cost ≈ $3–4 (Day 16's shape); Insights queries are $0.005 per GB scanned — megabytes.

---

## The evening before (or first thing) — the Day 19 bot on kind

The bot gained a CloudWatch logs backend (`enrich.py`), a ServiceAccount and boto3. Phase 2 of
the warm start pushes **the bytes kind runs**, so the build has to exist on kind first:

```bash
cd ~ && rm -rf /tmp/day19 && python3 -c "import zipfile; zipfile.ZipFile('/mnt/c/Users/bkala/Downloads/bhn-sim-day19.zip').extractall('/tmp/day19')"
cp -r /tmp/day19/bhn-sim/. ~/bhn-sim/ && chmod +x ~/bhn-sim/scripts/*.sh ~/bhn-sim/gameday/*.sh && cd ~/bhn-sim && git status --short | wc -l
git add -A && git commit -m "Day 19: CloudWatch logs collector (Pod Identity), game day 2, warm start"
```

Jenkins → **deploy-service** → `SERVICE=incident-bot`, change cause `Day 19: CloudWatch logs backend` → Build.
(29 tests incl. the SPL→Insights translator; on kind nothing changes at runtime — `LOGS_BACKEND` stays `splunk`.)

## Step 1 — Warm start, timed (terminal 1; ~40 min, most of it EKS)

```bash
aws sso login --profile lab
./scripts/190-eks-warm-start.sh
```

Eight phases, each a script you have: network (152, skipped if the VPC is up) → images
(153: the bot's new tag) → cluster (160 plan/apply — **+3 resources**: the bot's IAM role,
its policy, its Pod Identity association — then 161) → platform (162 plan/apply) →
services (163) → the deltas (172 for the KB, 181 `--verify` for the routing, and the three
collectors — expect `logs ok (cloudwatch)` for the first time) → traffic (**terminal 2:**
`./scripts/164-eks-traffic.sh`) → the first brief (`reports/daily/<date>-eks-warm.md`).
Answer `yes` to the three Terraform prompts. If a phase fails, fix it and
`190 --from N` (the clock keeps running from the first *begun* line; a phase you finished by
hand goes in the log with `190 --mark N label`). At the end it prints the minutes: write them into the README paragraph
*"The infrastructure story in two numbers"*. Read the brief's HEADLINE: if it does not say
healthy, believe it and fix before the game.

Terminal 3, for the afternoon: `KUBE_CONTEXT=aws-lab GRAFANA_PORT=3001 ./scripts/06-grafana.sh`.

## Step 2 — The scenario: sealed, started, walked away from

```bash
GAMEDAY_RUN=2 ./scripts/192-gameday2.sh start
```

Preconditions on aws-lab (no open tickets, knobs at baseline, remediator live with the
settlement signature, three collectors, the KB, Day 18's rules, traffic), then
`gameday/scenario-2.sh` runs in the background with jittered gaps. **Do not read it.**
Walk away five minutes. Then come back as if paged.

## Step 3 — Respond, using everything (~60–80 min)

Every tool is the same as on kind with `KUBE_CONTEXT=aws-lab` in front (`export` it in
the terminal you respond from). `192 status` is the second responder's view. Scribe as you
go: `GAMEDAY_RUN=2 ./gameday/note.sh "…"` for your timeline, `inc.py note <id> "…"` on
the tickets — the resolution drafts and the closing brief are only as good as this.

The shape of a good run, to grade yourself against afterwards (not before):

- one incident that should be **investigated and left alone** — the copilot question is
  *"activation is slow but not failing — what changed, and is any dependency implicated?"*
  and the honest conclusion names the limit of what the lab can know;
- one that the **machine should handle** — watch the remediator fail twice, then be the
  vendor (reset the mode when you have seen the second failure), then watch the next
  automated run succeed and the ticket close with no further human action;
- one that must be **escalated outside** — the hypothesis should cite the KB entry by id
  and say "partner", and the remediator must not touch it. Post the would-be partner
  ticket as a note, then resolve by resetting the rate.

```bash
GAMEDAY_RUN=2 ./scripts/192-gameday2.sh verify     # 0 of 3 faults live, tickets resolved, drafts, notes
GAMEDAY_RUN=2 ./scripts/192-gameday2.sh report     # the closing brief: all three, unprompted?
```

## Step 4 — Retro, with the series behind it

```bash
GAMEDAY_RUN=2 ./scripts/192-gameday2.sh retro
```

Ground truth (the scenario and its log) beside your timeline and the three tickets, TTD
and TTR computed for the KPI rows, then the scaffolds: `incidents/INC-0020.md`,
`INC-0021.md`, `INC-0022.md`, `gameday/retro-2.md` (Day 14's template plus the graduation
questions). Write them. Then `docs/ops-kpis.md` rows 0020–0022, **Eval 10** in
`docs/ai-eval.md` (three hypotheses and the closing brief), the papercuts table in
`docs/eks-notes.md`, and the warm-start number in the README.

## Step 5 — Destroy, verify, record

```bash
git add -A && git commit -m "Day 19: game day 2 on EKS — INC-0020..0022, retro-2, Eval 10, warm start N min"
./scripts/167-eks-teardown.sh --all         # platform -> cluster -> log group -> env; ends with 155 (every region)
./scripts/198-checkpoint-day19.sh
```

Tomorrow morning: `./scripts/154-aws-cost.sh --row 19` and the week's total into
`docs/aws-costs.md`. Kept on purpose: the state bucket, ECR, IAM, the budget — the
environment stays one apply away, and costs nothing while it sleeps.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| 190 phase 2: `153` rebuilds instead of retagging | the tag kind runs is not in the local daemon (Jenkins built it inside its own docker) — it rebuilds with buildx; check `--verify` says amd64 |
| 190 phase 3: plan shows only +3 (role/policy/association) | correct on a warm start: the cluster is new, so it is `+N` for the cluster too; +3 alone means the cluster already exists |
| 190 phase 6: logs collector `FAIL … cloudwatch` | `kubectl --context aws-lab -n payments logs deploy/incident-bot \| grep -i -E 'cloudwatch|credential'`; the Pod Identity association is on `payments/incident-bot` — the SA must exist (k8s/incident-bot.yaml, Day 19) and the pod must have been (re)started after the association |
| `AccessDeniedException … logs:StartQuery` | the IAM policy scopes the group `/bhn-sim/containers`; the group name must match what Fluent Bit created |
| copilot answers about kind during the game | `export KUBE_CONTEXT=aws-lab` in that terminal; the system prompt now says which cluster it is on — read the first line of its answer |
| `pkill -f port-forward` | stale forwards from a previous 164; then start 164 again |
| the latency fault never opens a ticket | it takes ~9 min (the 1h window must cross 14.4×); `192 status` shows the burn rate climbing. If p95 is not rising at all, the knob did not land: `kubectl --context aws-lab -n payments get deploy activation -o yaml \| grep BASE_LATENCY` |
| the remediator acts on the latency incident | it must not (no signature). If it did, a `detect` is too loose — a retro finding |
| settlement never self-heals after the reset | the next cron tick is up to 5 min; `kubectl --context aws-lab -n payments get jobs`; the tier-1 retry may already have used its one retry — the *cron* run is the one that succeeds |
| the email hypothesis does not cite kb-003 | `kb_matches` on the record: offered and ignored (model) vs not offered (retrieval: `KUBE_CONTEXT=aws-lab ./scripts/172-kb.sh --search "EgiftHighErrorRate send_email"`) |
| `167 --all` leaves the env root | it did on Day 16 — `./scripts/152-aws-vpc.sh destroy` by hand, then `155` |

---

## What's next

Day 20: no new systems. The repo becomes a portfolio, the experience becomes a first-90-days
plan, and the series ends the way a good incident does — with a written record and named
follow-ups.
