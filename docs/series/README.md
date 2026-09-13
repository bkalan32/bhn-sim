# The series — twenty days, one line each

Each day has a guide (`DAYn.md`, adapted from the PDF to this lab: Windows + WSL2, kind,
us-east-2) and a corrections file (`CORRECTIONS-DAYn.md`: **B** = the guide was wrong, **D** = a
design decision that differs, **N** = a note). The corrections total **265 items** across
nineteen days; they are the most honest part of the record, because every one was found by
running the thing.

| Day | Guide | What was built | The one thing to remember | Corrections |
|---|---|---|---|---|
| 1 | [Building a local incident response lab](../../DAY1.md) | WSL2, Docker, kind, kube-prometheus-stack, Jenkins; the rebuild-from-zero runbook | `.wslconfig` shapes the VM, not Docker's settings; 30 minutes of command replay is the first number | [15](../../CORRECTIONS-DAY1.md) |
| 2 | [Your first production service](../../DAY2.md) | activation API with fraud/issuer mocks, structured logs, metrics, the first dashboard | a service that lies about its health (2 % baseline errors) is the right first service | [9](../../CORRECTIONS-DAY2.md) |
| 3 | [Logs, Splunk, and the first alert](../../DAY3.md) | Fluent Bit → Splunk HEC, the `by app.reason` search, `ActivationHighErrorRate`; INC-0001 | the first diagnosis took ten minutes of writing a search — the number everything later is measured against | [11](../../CORRECTIONS-DAY3.md) |
| 4 | [A second service and distributed tracing](../../DAY4.md) | egift (activate → send_email), OTel → Tempo, trace → log correlation; INC-0002/0003 | two incidents found by a human on a dashboard: the gap the next fortnight closes | [11](../../CORRECTIONS-DAY4.md) |
| 5 | [SLOs, error budgets, and the silent failure](../../DAY5.md) | SLOs, burn-rate alerts, the settlement CronJob, `SettlementZeroRecords` ("a good thing stopped happening"); INC-0004/0005 | alert on absence — the pattern that finds silent failures everywhere | [8](../../CORRECTIONS-DAY5.md) |
| 6 | [CI/CD, the bad deploy, and the rollback](../../DAY6.md) | Jenkins deploy-service: test → build → deploy → verify → auto-rollback, Grafana deploy annotations; INC-0006 | the pipeline is the first responder for one whole class of incident | [12](../../CORRECTIONS-DAY6.md) |
| 7 | [The health score, the overview, and the first real fix](../../DAY7.md) | health score that actually moves, Platform Overview, fail-fast on the fraud call (3 s → 0.3 s); week-1 review | the cheapest fix with the biggest effect was a timeout | [6](../../CORRECTIONS-DAY7.md) |
| 8 | [Alert routing and your own incident bot](../../DAY8.md) | severity routing (page / ticket / null), the incident-bot (tickets, timelines, notes), the settlement self-check; INC-0007 | the ticket is the record; everything after this writes to it | [12](../../CORRECTIONS-DAY8.md) |
| 9 | [AI incident summaries and communications](../../DAY9.md) | open / resolved drafts from the record, the eval discipline (`docs/ai-eval.md`), the first hallucinations kept; INC-0008 | drafts, not decisions; a documented failure with its cause is the deliverable | [9](../../CORRECTIONS-DAY9.md) |
| 10 | [Context-enriched alerts and the first AI diagnosis](../../DAY10.md) | three collectors (metrics, deploys, logs) on every ticket, the hypothesis draft, the KPI table; INC-0009/0010 | the right cause on the ticket 43 s after the alert — and the wrong event ranked first once | [11](../../CORRECTIONS-DAY10.md) |
| 11 | [The operational copilot](../../DAY11.md) | a CLI copilot with read-only hands (Prometheus, Splunk, deploys, kubectl get), transcripts graded; INC-0011 | found the cause 31 s before the alert; an allow-list is a security boundary, not a convenience | [14](../../CORRECTIONS-DAY11.md) |
| 12 | [Auto-remediation, with the safety on](../../DAY12.md) | the remediator: signatures, tiers (auto / approve / human), bounded retry, cooldown, dry-run; INC-0012–0014 | one human decision, 35 s; 389 s end to end; the machine reports when its fix did not stick | [20](../../CORRECTIONS-DAY12.md) |
| 13 | [Infrastructure as code, locally](../../DAY13.md) | Terraform owns the platform layer, nightly drift check in Jenkins, secrets out of state; INC-0015 | the incident nothing can alert on (an untracked change) is caught by `plan -detailed-exitcode` | [23](../../CORRECTIONS-DAY13.md) |
| 14 | [Game day](../../DAY14.md) | two sealed faults, a strict timeline, the retro, the KPI dataset, the morning routine; INC-0016/0017 | did anything you built mislead you? — the question every retro since has asked | [12](../../CORRECTIONS-DAY14.md) |
| 15 | [AWS foundations, guardrails first](../../DAY15.md) | budget alarm before the first resource, SSO not keys, remote state, VPC + ECR by Terraform, the every-region sweep | the lab lives in one region; the bill does not | [21](../../CORRECTIONS-DAY15.md) |
| 16 | [EKS: create, learn, destroy](../../DAY16.md) | EKS by Terraform (its own state), the platform layer on it with three commented differences, the Day 10 drill on EKS, torn down the same day; INC-0018 | zero application changes, one manifest line — and two sources of three, because Splunk lives on the laptop | [25](../../CORRECTIONS-DAY16.md) |
| 17 | [New Relic, and the knowledge base](../../DAY17.md) | New Relic via remote-write with a keep-list, `kb/` as a ConfigMap in the hypothesis prompt, the KB feeding rule; INC-0019 | same model, same fault, same sources: medium → high confidence — the difference is the memory | [18](../../CORRECTIONS-DAY17.md) |
| 18 | [Alert hygiene, the KPI set, and the daily ops report](../../DAY18.md) | the alert audit (169 rules judged), warning = ticket, seven KPIs defined with sources, a 250-word daily brief at 07:00 from Jenkins | the report can only see what the record holds | [16](../../CORRECTIONS-DAY18.md) |
| 19 | [Final game day, on AWS](../../DAY19.md) | the timed warm start (121 min), CloudWatch as the third collector via Pod Identity, three faults with three different right answers, torn down and verified; INC-0020–0022 | machines for the known, humans for the ambiguous and the external — with timestamps | [12](../../CORRECTIONS-DAY19.md) |
| 20 | [The write-up, the portfolio, and the first 90 days](../../DAY20.md) | the README front door, this index, `docs/demo.md`, `docs/first-90-days.md`, `docs/series-retro.md`, the tag | reliability is engineered in loops; the tooling tightens each loop without letting go of the wheel | [—](../../CORRECTIONS-DAY20.md) |

## Publishing

The decision, recorded (Day 20, Step 2): the account exists and has never posted. The series
will be published **two posts a week, in this order**, each one a rewrite of the day's guide
plus its corrections into a single narrative with the incident's numbers — not the runbook:

1. **Game day 2 on AWS** (Day 19) — three faults, three different right answers, with
   timestamps. The post with the most evidence in it goes first.
2. **The lab in one screen** (Day 20's README front door) — what, the diagram, the numbers.
3. Then Days 1 → 18 in order, one per post, each ending with "what the guide got wrong".

Rules: a post is not published until its day's checkpoint passed; every number in a post is in
`docs/ops-kpis.md` or an incident file; no screenshots of vendor consoles with account ids.
The cadence is the commitment — two a week beats twenty at once and then silence.
