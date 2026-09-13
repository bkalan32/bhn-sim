# The first 90 days — translating the lab to the job

> **Two rules, written first, for me.**
> (1) For the first month, prefer questions to suggestions.
> (2) Never say "at my lab" in a meeting more than once a week.
> The lab's value is that it trained my instincts; it does not resemble their production, and
> the fastest way to lose a room is to imply that it does.

The frame: twenty days taught me the *shapes* — the loop of detect, diagnose, fix, learn; where
a human belongs in it; what a record is for. The job supplies the specifics, at a scale and
messiness a laptop cannot fake. So this plan is mostly about learning speed, with the build
as the accelerant, and each phase ends with something small that shipped through *their*
process, because learning the process is half the point.

## Days 1–30 — learn the territory

**Be the scribe.** Shadow every on-call and every bridge I am allowed into, and volunteer to
keep the timeline. I have done exactly this for two game days and every drill: the scribe is
the person who learns fastest while being useful, and a timeline with reasons ("not acting,
because…") is worth more to the retro than any other artefact. Deliverable: the timeline of
the first real incident I sit in, in whatever format they use.

**Map the money.** The way Day 1 mapped card activation → eGift → settlement: which flows move
money, what each depends on, which dashboard shows each one, which alert would fire if it
stopped, and — Day 5's question — what is *expected every N minutes* and would fail silently
if it just stopped happening. Deliverable: one page, in their wiki, reviewed by someone who
has been there a year.

**Find the real versions of everything I built**, and write down how alive each one is:

| the lab's | the company's | questions to answer by day 30 |
|---|---|---|
| Alertmanager routing (page / ticket / null) | their paging tool and routing rules | who decides severity? what is routed to nowhere on purpose, and is that written down? |
| the incident-bot's tickets and timelines | their incident tool | what does a good record look like here? do timelines have reasons or only actions? |
| `kb/` | the last ten post-incident reviews | are follow-ups tracked to closure? which patterns recur? (this *is* their KB whether or not anyone calls it that) |
| the remediator's tiers | any automation that acts on alerts | what can act without a human, and who reviewed that list, and when? |
| `terraform plan` nightly | their IaC and its drift story | what changes outside the pipeline, and how would anyone know? |
| the daily brief | their morning ritual, if any | what does the on-call read first? |

**Take nothing on faith about the tooling.** The lab's lesson from every retro: the thing
most likely to mislead a responder is something a colleague built with good intentions — a
health score that does not move (Day 7), a runbook line that drifted (Day 14), a KB sentence
that was true until a fix changed it (Day 19). Notice these; do not fix them yet; write them
down.

## Days 31–60 — contribute on the edges

**Take on-call in the rotation**, with the scribe's notebook still open.

**Ship small, welcome things through their real process.** The lab prepared me for exactly
these, and each is one review away from merged:

- *A noisy alert tuned, with a written rationale* — the Day 18 method: hours firing, tickets
  produced, the judgment (keep / warning / null / fix), verified with the routing tool before
  and after. One alert, one PR, the table in the description.
- *A runbook that drifted, re-audited against the running system* — the Day 14 habit: run each
  line, mark what still works, fix what does not, date the audit.
- *An "alert on absence"* for one expected-every-N process — Day 5's pattern finds these in
  every system: a batch that stopped, a queue nobody drains, a cron that silently exits 0.
- *A dashboard gap* found during on-call — one panel, with the query in the PR.

**Measure before suggesting.** If there is a KPI table, read its definitions; if there is
not, do not propose one yet — collect the five columns (detected by, TTD, TTDiag, TTR, mode)
for the incidents I sit in, privately, so that when the conversation happens I have their
numbers, not mine.

## Days 61–90 — propose one system

By now I will have seen which of the lab's ideas the team lacks *and would adopt*. Propose
one — small, with the safety framing I practised — and offer the lab as the working prototype,
because arriving with a demo beats arriving with a slide. Candidates, in the order I would
expect them to land:

1. **Enriched context on tickets** — three sources attached before anyone looks (metrics
   snapshot, recent changes, log reason histogram). Lowest risk, no AI, no actions; the Day 10
   design, and the thing that took diagnosis from ten minutes to one.
2. **A KB template with a feeding rule** — symptoms, discriminating checks, fix, tier, learned
   from; and the rule that every post-incident review ends with the entry it changed. Day 17.
3. **An AI incident-summary draft with the Day 9 guardrails** — drafts not decisions, quotes
   the record, says "no responder actions recorded" rather than inventing them, and an eval
   log where the failures are kept. Only after 1 and 2 exist, because it reads them.
4. **A daily brief** — 250 words at 07:00, every number traceable, a "needs a human" section.
   Day 18. The one most likely to be read by people outside the team.

Not on the list: auto-remediation. The lab's tiered policy works because I wrote every
signature; proposing that a machine act on someone else's production in the first 90 days is
the "at my lab" mistake in its most expensive form. The remediator is the thing I *talk*
about — the tiers, the bounded retry, "a second failure is a human's problem" — when the
conversation about automation happens, and the evidence is INC-0013 and INC-0021.

## The gap list — what twenty days could not cover

Honest inventory, so continued learning is aimed rather than vague. One line each on how I
will close it; mostly on the job, deliberately, with notes.

| gap | why the lab could not cover it | how I will close it |
|---|---|---|
| **Databases and stateful workloads under Kubernetes** | the lab was stateless by design (the settlement "database" is a mock; the ticket store is a JSON file in a pod) | shadow the DBA/platform team on one migration or failover; run a Postgres operator in the lab with a backup/restore drill; read the last three database incidents' reviews |
| **Networking depth** — DNS, load balancer internals, service mesh, network policy | one node on a laptop; on EKS one NLB, no mesh, no policies; the deepest network fault I met was a WSL DNS relay | trace one real request end to end with the network team (client → edge → LB → ingress → pod → dependency); a NetworkPolicy drill on the lab; a mesh only if they run one |
| **Security operations beyond hygiene** | the lab has secrets discipline and read-only AI hands, not detection, response or an IAM review at scale | the company's security on-call: shadow one week; read their last incident review; an IAM access review of the lab's own Pod Identity roles as practice |
| **Capacity planning and performance tuning under real load** | 5 req/s from a Python script; every performance fault was an env knob | learn their load-test tooling and one capacity model; profile one real hot path; the lab's health score under a real load test |
| **Vendor consoles at production scale** | Splunk and New Relic at free-tier volumes; CloudWatch at kilobytes | the difference is cost and query discipline: sit with whoever owns the observability bill; learn the retention and sampling decisions and why |
| **Stateful, multi-region, multi-team incidents** | one region, one responder, faults I could seal in a file | the bridges — as scribe first; read how their incident commander role works and what a comms lead does |
| **Their stack** — whatever it adds (a different cloud, a different CI, a queue, a mesh, a mainframe) | unknowable from here | the first 30 days' map; one page per system I touch, in their wiki, corrected by an owner |

What the lab *did* cover well enough to stand on: the incident loop end to end; SLOs and
burn-rate alerting; alert hygiene with written judgment; CI/CD with verify and rollback;
IaC with drift detection; tiered automation with a safety argument; evaluating an AI system
on the record; running a game day and writing a retro that names what misled you; and the
discipline of a record that a stranger can read.
