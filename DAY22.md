# Day 22 — Mission Control, part 2: the Overview and the incident page

Source: `day-21-25-final-challenge-mission-control.pdf`, Day 22 · adapted to this lab.
Corrections: `CORRECTIONS-DAY22.md`.

## What we are building, and why

Day 21 gave the platform a control plane you could only reach with `curl` and `tools/mc.py`.
Day 22 gives it a screen — the one an on-call engineer opens at 3 AM. Two pages carry the day:

**The Overview — the ten-second screen.** Day 7's Platform Overview, live: the platform health
score large with its Day 7 thresholds, the three service scores with 1-hour sparklines, critical
alerts, open incidents, deploys today, settlement age; the live feed down the right (alerts,
incidents, actions, approvals, deploys — the bridge scribe's screen when nobody is scribing); the
golden-signal panels *embedded* from Grafana (dashboards stay dashboards-as-code); the last ten
audit rows. And on every page, **the pending-approvals banner** — the Slack button Day 12
promised.

**The incident page — the heart of the product.** Days 9, 10, 12 and 17 laid out for a human:
the header (ID, severity, status, duration, alert→ticket time), the context card with every
number deep-linked to the query that produced it, the hypothesis with its confidence and the
KB entries it cited as chips, the timeline with a note box (tier 1, audited under your name), the
actions rail (proposals waiting, the tier-1 buttons, the tier-2 requests, and for tier-3
situations a grey card that says *no safe automated action: escalate* with the KB's fix text),
and the AI drafts with a copy button per part and a thumbs up/down that writes an eval row.

Why a screen at all, when the terminal works: game day 3 (Day 25) is run **with no terminal**.
Every capability that exists only as a command is a capability you will not have that day.

## What changed in the repo

| Where | What |
|---|---|
| `services/mission-control/ui/` | the React app: React 19 · Vite 8 · TypeScript 7 · TanStack Query · Tailwind 4 · Recharts |
| `services/mission-control/Dockerfile` | two stages: Node builds the UI (type-check first), Python serves it from `/` |
| `services/mission-control/app.py` | `/` serves the UI with a CSP · `/api/config` · `/api/eval` · the poller also emits `incident`, `deploy` and remediator `approval` events · `/api/kb` fixed (B1) · 1-hour sparklines |
| `k8s/kps-values.yaml` | Grafana `allow_embedding` + anonymous **Viewer** (D1) — through Terraform |
| `dashboards/activation.json`, `egift.json` | panel ids pinned (D2) |
| `scripts/220-mc-open.sh` | the port-forwards (Mission Control + Grafana, self-healing), the token to your clipboard, the browser |
| `scripts/228-checkpoint-day22.sh` | the exit criteria |

## Steps

1. **Unpack, test.** `python3 -m pytest -q services/mission-control/tests` — 32 pass.
2. **Grafana embedding, through Terraform** — on a calm node (`uptime` under 4, CORRECTIONS-DAY21 B6):
   `./infra/local/tf.sh plan` shows one change (kps: `grafana.ini`), then `apply`. Grafana restarts.
3. **Re-provision the dashboards** so Grafana has the pinned panel ids: `./scripts/09-grafana-dashboards.sh`.
4. **Ship the image** — Jenkins `deploy-service`, `SERVICE=mission-control`. The first build of
   this image downloads Node and the npm packages: a few minutes longer than Day 21's.
5. **Open it:** `./scripts/220-mc-open.sh` — then, in the browser, your name and Ctrl+V.
6. **Commit** — then the drill.

## The first browser-only drill (PDF Step 3)

The console cannot inject faults until Day 24, so the command line queues both halves of the
fault *before* you stop using it; the browser does everything else — including the two
approvals, which are the Slack button the day promised.

| Where | What | Proves |
|---|---|---|
| terminal (last use) | `python3 tools/mc.py run set_fault target=activation knob=FRAUD_SVC_DOWN value=true --reason "Day 22 drill: fraud outage"` | |
| terminal (last use) | `python3 tools/mc.py run set_fault target=activation knob=FRAUD_SVC_DOWN value=false --reason "Day 22 drill: provider recovered"` | both wait in the banner (30 min) |
| browser | **start the clock.** Banner → **Approve** the `value=true` card | tier-2 approval from the banner, your name in the audit |
| browser | watch the feed: `ActivationHighErrorRate firing`, then `INC-… opened` (~4 min) | the feed updates without reload |
| browser | open the incident: context, hypothesis (should cite **kb-001**), the grey **escalate** card | the incident page |
| browser | post **two notes** (what you saw; what you escalated) | tier 1 from the page |
| browser | banner → **Approve** the `value=false` card ("the provider recovered") | |
| browser | watch the incident resolve, the **resolution draft** appear; **👍** it (or 👎 with a reason) | eval row |
| browser | **stop the clock** | |

Then, terminal again: `python3 tools/mc.py audit 20` and the incident id, for `INC-0023`
("first incident handled without a terminal"), then `./scripts/228-checkpoint-day22.sh`.

**Done when:** `228` passes — the UI served with its CSP, 1-hour sparklines, the feed pushing,
Grafana embeddable to an anonymous Viewer (and not an admin), a note and a grade from the
browser, a tier-2 approval by button with your name and the token, INC-0023 committed, plan
clean.
