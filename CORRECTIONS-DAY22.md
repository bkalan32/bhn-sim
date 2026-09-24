# Day 22 — Corrections Log

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 22 · built 23 Sep 2026 on the lab
Day 21 left (mission-control:53, the third webhook live). Versions verified that day: React
19.3, Vite 8.3 (Rolldown), TypeScript 7.0 (the native compiler), TanStack Query 5.103,
Tailwind CSS 4.3, Recharts 3.10, Node 24 for the build stage.

---

### [BUG] B1 — `/api/kb` had been a 500 since Day 21

Found by rendering the KB page against the real `kb/*.md` before anything shipped. Every
kubectl call in `actions.py` returned the **last 1,500 characters** of its output — right for
an audit row, where the end of a long error is the useful part. The KB route parses
`kubectl get configmap kb -o json` (~20 KB), so it parsed the *tail* of a JSON document and
failed on the first character. Day 21's tests ran in DRY_RUN, where the route never called
kubectl, and no Day 21 drill opened the KB — so the route was listed, documented, and broken.
**Fix:** `kubectl(…, keep=None)` for reads that parse their output; a test feeds the real KB
through a fake kubectl binary (`test_kb_route_parses_a_real_sized_configmap`). The lesson is
the one from Day 21 N7 again: a check that never exercises the real path proves nothing.

### [BUG] B2 — The live feed announced every deploy again every 15 seconds

First look at mission-control:54 in the browser: the feed's top four items were the same
"deploy · mission-control · build 54", fifteen seconds apart. The poller asked Grafana for
annotations `from` the last one it had seen — and Grafana applies its time filter only when
**both** `from` and `to` are given; with `from` alone it returned the whole list, every pass.
The fake Grafana used for the render test honoured `from` on its own, so the test could not
see it: a fake that is more obliging than the real thing hides exactly this kind of bug.
**Fix:** both bounds on every annotation query (the "deploys today" tile had the same flaw), the
time also checked in the poller, and the feed keys a deploy by the annotation's time and
service, so even a repeated event is shown once. Test: a Grafana that ignores the filter,
four passes, one event.

### [NOTE] N1 — The draft splitter cut "INTERNAL SUMMARY" after four letters

The incident page splits each AI draft at its numbered headings so every part gets its own
copy button. The first version's heading pattern was *lazy* and stopped at `INTE`, leaving
`RNAL SUMMARY (for engineers…)` as the body. The type checker was happy; the screenshot was
not. Now greedy up to the last capital before `(` or `:`, and checked against the bot's three
real prompt shapes (open, hypothesis, resolved). Rendering the page before shipping it is a
step, not a nicety.

---

### [DESIGN] D1 — Grafana panels: allow_embedding + an anonymous VIEWER, and two port-forwards

The PDF: *"Enable allow_embedding in the Grafana Helm values and create a viewer service
account."* Both halves meet one fact: **an iframe cannot carry a token.** The browser loads the
panel itself, sends no Authorization header, and a service-account token in the iframe URL
would sit in the browser history and Grafana's access log. The choices were an auth proxy
(OIDC — a company's answer), a reverse proxy in Mission Control that injects the token (Grafana
then needs `serve_from_sub_path`, which moves every existing Grafana URL the scripts and the
pipeline use), or **anonymous access with the Viewer role** on a Grafana that is a ClusterIP
reached only by a port-forward on your own machine. The lab takes the third, in
`k8s/kps-values.yaml` through Terraform, with the swap written next to it. The Viewer *service
account* from Day 10 (`secret/enrich-config`) is still what Mission Control's server side uses
(deploys today, the feed's deploy events). `228` proves both halves: an anonymous read of a
dashboard works, an anonymous read of the admin settings does not.

Consequence: the PDF's "the only port-forward you ever need again is this one" becomes two —
Grafana's on :3000, because the *browser* loads the panels. `scripts/220-mc-open.sh` starts
both, each in a loop that reconnects after a pod restart (a mission-control deploy during a
drill must not leave a terminal-free operator looking at a dead page).

### [DESIGN] D2 — Panel ids are pinned in `dashboards/*.json`

The embed URLs name panels by id (`d-solo/bhn-activation?panelId=5`). The dashboard JSON had
no ids: Grafana assigned them on load, in document order — so reordering a dashboard would
have silently pointed the Overview at a different graph. Ids are now written in the JSON
(sequential, rows included — what Grafana would have assigned, so nothing moved), and
`config.EMBED_PANELS` names them. `228` checks Grafana's provisioned copy has 5/6/7.

### [DESIGN] D3 — The UI lives in `services/mission-control/ui/`, not `ui/` at the repo root

The pipeline builds `docker build .` inside `services/<SERVICE>/`: a root-level `ui/` would be
outside the build context. One multi-stage Dockerfile: `node:24-slim` runs `npm ci` and
`npm run build` (which type-checks first, so a type error fails the pipeline's Build stage,
not a browser), and only `dist/` is copied into the Python image. No node in the running
container. `.dockerignore` keeps the Test stage's venv and any local `node_modules` out.

### [DESIGN] D4 — shadcn/ui's style without the generator, and a hash router without a library

shadcn/ui is not a dependency: it is a CLI that copies component source into your repo. The
four this UI needs (card, button, badge, status marker) are 150 lines in
`components/ui.tsx`, in its conventions (Tailwind classes, variants as props), with no Radix
dependency. Routing is `#/incidents/INC-…` in twenty lines (`lib/router.ts`): the server only
ever serves `/`, so a reload or a pasted link can never 404, and there is no route table to
keep in sync with FastAPI.

### [DESIGN] D5 — The token in the browser: pasted once, kept per tab, fenced by a CSP

The login box takes a name (for `X-Operator`) and the bearer token; the token is checked against
`/api/config` before it is kept, and kept in **sessionStorage** — this tab only, gone when it
closes; never localStorage (outlives the session), never a cookie (the browser would attach it
to requests the page did not make). `220` puts it on the Windows clipboard with `clip.exe`, so it
is never printed. The page ships a Content-Security-Policy: scripts only from itself, `fetch`
and SSE only to itself, iframes only from Grafana, no framing of Mission Control by anything.
The SSE stream still takes its token in the URL (Day 21 D7); the CSP means the page cannot
send it anywhere else.

### [DESIGN] D6 — A tier-2 button REQUESTS; the Approve in the banner executes — even for you

The PDF: "click shows a confirmation card with the rationale and blast radius; second click
executes." On the incident page the card's button is **Request — needs approval**: it creates the
same pending approval `tools/mc.py run` creates, and the Approve click in the banner (or the
incident's rail) executes it. Three clicks instead of two when requester and approver are the
same person. Worth it: there is ONE place a tier-2 action is executed from, whoever asked — you,
the remediator, or on Day 23 the copilot, which can request and must never approve. A card
that executed on its own second click would be a second path.

### [DESIGN] D7 — Incident, deploy and remediator events come from a 15-second diff

The PDF fans "every incident change" and "remediator notes" out over SSE. The bot, the
remediator and Grafana have no push — only the Alertmanager webhook does. The poller that
already pushes health scores every 15 s now also diffs the bot's open incidents (`incident`
opened/resolved), the remediator's pending list (`approval` proposed) and Grafana's
deploy/rollback annotations (`deploy`). Its first pass records the present without
announcing it, so a restart does not replay every open incident into every tab as "opened"
(`test_poller_announces_changes_not_the_present`). Worst case, an event is 15 s late; the
alert that caused it is not. What still needs the incident page's own 10 s poll: drafts and
context the bot attaches in the background.

### [DESIGN] D8 — A thumbs up/down is not a catalog action, but it is audited like one

`POST /api/eval` writes Mission Control's own `evals` table (incident, draft, verdict, comment,
model, who) — the structured start of `docs/ai-eval.md` that Day 23's eval screen reads. It
changes nothing in the platform, so it is not in the action catalog; it still writes an audit
row (`rate_draft`, tier 1), because "who graded the AI, and when" is exactly the kind of thing
the audit log is for.

### [DESIGN] D9 — Every number on the incident page links to the query that produced it

The context card deep-links each metric to Grafana Explore and the log histogram to Splunk,
with the time window around the incident. The bot's records carry the numbers, not the
PromQL, so `config.METRIC_QUERIES` mirrors `services/incident-bot/enrich.py` — and
`test_metric_queries_mirror_the_bot` reads the bot's source in the same checkout and fails on
any drift. A link that opens a *different* query from the one behind the number is worse than
no link.

---

### [NOTE] N2 — Sparklines are one hour now

Day 21's overview returned 30 minutes; the PDF's Overview asks for 1-hour sparklines. One point
a minute, 61 points, Recharts, one series per tile (no legend; the title names it), a faint rule
at 90 ("meeting SLOs"), hover for the exact value.

### [NOTE] N3 — One theme, dark

This is the 3 AM screen and the embedded Grafana panels are dark (`theme=dark`). Status
colours mark dots and edges and always come with an icon and a word — critical red is 3.6:1
on the dark surface, too low to carry small text on its own.

### [NOTE] N4 — The bundle is 655 KB (195 KB gzipped), mostly Recharts

For a single-operator console loaded once per shift through a port-forward, that is fine. Day
23's copilot screen is the natural place to code-split if it grows.

### [NOTE] N5 — The AI started writing markdown; the page showed the `##` and `**`

The first real incident on the page (INC-0023's) had a hypothesis full of `## 1. WHAT WE KNOW`,
`**bold**` and a ```` ```promql ```` block: the bot's model writes markdown whether the prompt asks
for it or not. The render test's fake drafts were plain text — again a fake more polite than the
real thing (B2). `components/markdown.tsx` renders the subset the drafts use (headings, bold,
inline and fenced code, lists — keeping the model's own numbering, so "5. CONFIDENCE" is not
shown as "1.") as React elements. No HTML is injected: the text comes from a model, and the page
has a CSP to keep. The copy buttons still copy the markdown source, which is what a Slack or
Jira paste wants.

### [NOTE] N6 — The first drill found an outage the platform had not: the log pipeline

INC-0023's context card said "no error-status events for activation in the last 10m" while
activation failed seven requests a second. Both hypotheses (activation and egift) noticed the
contradiction, said so, and lowered their confidence to medium instead of inventing a histogram
— the Day 10 rule working as designed. The cause was two restarts' worth of drift
(CORRECTIONS-REBUILD B10, B11). What did not work: nothing paged. A log pipeline down for five
hours is an incident; Day 24 adds the alert.

### [NOTE] N7 — The checkpoint counted history, not the range

`228` first failed with "sparklines: 41 points (want ~61)". The overview asks Prometheus for one
hour at one point a minute; Prometheus answers with the points it *has*, and after the restart it
had 41 minutes of unbroken `activation:health_score`. The check was testing the lab's uptime,
not the code. It now tests what Day 22 changed — more than 31 points, which a 30-minute range
cannot return — and the tile fills back to 61 on its own.
