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
| 0001 | (pre-bot, Day 3) | fraud dependency | ~2 min | – | – | – | ~10 min (alert → Grafana → write the Splunk `by app.reason` search) | – | – | first time; the search had to be written |
| 0002 | (pre-bot, Day 4) | activation latency (exp. A) | human on dashboard | – | – | – | ~0 — the experiment *was* the cause | – | – | no alert existed yet |
| 0003 | (pre-bot, Day 4) | email latency (exp. B) | human on dashboard | – | – | – | ~0 — same | – | – | no alert existed yet |
| 0004 | (pre-bot, Day 5) | 50% errors | ~2 min (BurnFast) | – | – | – | n/a — cause was the drill | – | – | |
| 0005 | (pre-bot, Day 5) | silent settlement | ~1 min (ZeroRecords) | – | – | – | ~2 min (the alert name *is* the diagnosis) | – | – | Stale would have taken 15 min more |
| 0006 | (pre-bot, Day 6) | bad deploy | ~2 min | – | – | – | ~0 — the deploy annotation *was* the diagnosis | – | – | pipeline rolled back |
| 0007 | `INC-1788559916-4b4b` | fraud dependency (Day 8) | ~2 min | 16s | – | – | n/a — no responder notes; the ticket had names and times, not the cause | – | – | first ticketed incident |
| 0008 | `INC-1788806049-78f7` | fraud dependency (Day 9) | ~2 min | 29s | – | – | **4m37s** (note 1 at 18:38:46, alert 18:33:40) | – | – | human diagnosis while reading a draft |
| 0009-leak | `INC-1788825339-a7fd` | fraud dependency (Day 10, invalid) | 195s | 30s | 0s | 22s | – | (52s — not counted: the answer was in the input) | ⛔ | Eval 3-leak; logs collector "no events" (Fluent Bit → old Splunk IP) |
| 0009 | `INC-1788827585-6b7f` | fraud dependency (Day 10) | **156s** | 25s | 0s | 18s | – (none needed) | **43s** (TTT 25 + TTH 18) | **yes** | 435× fraud_service_timeout, no deploys; medium confidence, honest |
| 0010 | `INC-1788828923-e7d8` | bad deploy (Day 10, build 19) | ~156s (deploy 2.6 min before the alert) | 18s | 0s | 24s | – | 42s → **not counted** — the right cause was ranked second | half | rollback landed 0.3 min *before* the alert; hypothesis blamed the rollback |
| 0011 | `INC-1788884439-d9d2` | fraud dependency (Day 11, copilot) | ~188s | 29s | _kpis.py_ | _kpis.py_ | – | bot: TTT + TTH (right) · **copilot: 22 s from the question = 157 s from the fault, 31 s BEFORE the alert** | **yes** (both) | copilot asked at t+135 s; its Q3 invented a deploy story (Eval 4b) |

| 0012 | `INC-1788902287-0232` | crash-looping pod (Day 12, tier 1) | 264s (`PaymentsPodCrashLooping`, restart branch, `for: 1m`) | 17s | _kpis.py_ | _kpis.py_ | – | – (the signature IS the diagnosis) | yes | **AUTO +1 s** (read the pod, confirmed CrashLoopBackOff, deleted *that* pod) → +90 s *"restart did NOT stick … a human is needed"* — the honest outcome; resolved ≈2 min after the fixture was removed |
| 0013 | `INC-1788902731-4fad` | settlement crash (Day 12, tier 1) | 140s (`SettlementJobFailed`) | 18s | _kpis.py_ | _kpis.py_ | – | – | yes | AUTO attempt 1 **FAILED** (kubectl create timed out on API discovery — B12) → retry in 180 s → mode set to `none` by the human at +108 s → **AUTO retry succeeded** +285 s, Job Complete; alert resolved by its own 15-min window |
| 0014 | `INC-1788906062-bf85` | bad deploy, Verify skipped (Day 12, tier 2, run 2) | ~190s (deploy 3.2 min before the alert) | 28s | _kpis.py_ | _kpis.py_ | – | – (the remediator's signature IS the diagnosis: deploy 3.2 min before) | **yes** | **alert → PROPOSED 28 s → APPROVED +35 s → EXECUTED +13 s → RECOVERED +313 s**; approve → production healthy ~60 s; approve → alert resolved 326 s |
| 0014-r1 | `INC-1788904287-7074` | same, run 1 (verification forbidden — B13) | ~190s | 18s | | | – | – | yes (rollback) | PROPOSED +3 s → APPROVED +686 s → EXECUTED FAILED +185 s (rollback done, `rollout status` forbidden) → RECOVERED +210 s; alert → resolved 1102 s |
| 0015 | `INC-1788917278-ed1a` | **untracked infrastructure change** — pushgateway ServiceMonitor removed by a hand `helm upgrade` (Day 13 drift drill) | **none** — no alert can fire on a metric that no longer exists; a human declared it **8 m 18 s** after the change, and only because one was watching | – (declared → ticket 1 s) | – | – | ≈5 min (`terraform plan -detailed-exitcode` = 2, once the provider was made to compare live state — B8) | – (context attached, all settlement metrics `null`; hypothesis draft not graded — the cause was on the ticket before it ran) | yes (human) | change → repair **59 m 23 s**, of which ~48 min was fixing the tooling (B8, B10); declared → repaired 51.1 min. Nightly job proved: SUCCESS / **FAILURE** / SUCCESS. Copilot Eval 5: pass, gap reported as a footnote not a finding |
| 0015-b | (same ticket) | real `SettlementJobFailed` during the kps upgrade (VM under memory pressure) | 0 s (kube-state-metrics, not pushgateway) | – (landed on the open ticket) | – | – | – | – | – | tier 1 `rerun_settlement` **56 s** after the alert, Job Complete, 4 445 records, resolved +10 min; Day 12's automation inside Day 13's drill, nobody touched kubectl |
| 0015-fb | – (unticketed) | Fluent Bit killed by a 1 s liveness timeout every ~40 min for 5 h, 10 restarts, exit 0 each | **≈5 h**, by a human reading `RESTARTS` — nothing alerts on platform-namespace restarts | – | – | – | ~2 min (probe events) | – | yes (human) | fixed via Terraform (`timeoutSeconds: 5`, `bc155a4`); 0 restarts in the following 76 min vs 1 per ~40 min before; follow-up: restart alert for platform namespaces |

Cascade tickets from the same faults (egift calls activation): `INC-1788827580-2365` (with 0009) and
`INC-1788828924-519d` (with 0010) — TTT 25s/18s, TTH 22s/20s, no separate diagnosis graded.

## Week over week — every incident, five columns (Day 14, Step 1)

*Detected by* is the column that changed most; *mode* is the one that changed last.
Times approximate where they came from a terminal rather than the record. 0016/0017 are
filled after the game day.

| # | Day | Fault | Detected by | TTD | TTDiag (first correct cause on record) | TTR (alert → resolved) | Mode |
|---|---|---|---|---|---|---|---|
| 0001 | 3 | fraud dependency down | alert (`ActivationHighErrorRate`) | ≈2 min | ≈10 min, human (wrote the Splunk `by app.reason` search) | ≈15 min | manual |
| 0002 | 4 | activation latency (exp. A) | **human on a dashboard** | – | ≈0 (it was the experiment) | minutes, manual revert | manual |
| 0003 | 4 | email latency (exp. B) | **human on a dashboard** | – | ≈0 | minutes, manual revert | manual |
| 0004 | 5 | 50 % errors (burn) | alert (`…BurnFast`) | ≈2 min | ≈0 | ≈5 min | manual |
| 0005 | 5 | silent settlement (0 records) | alert (`SettlementZeroRecords`) | ≈1 min | ≈2 min (the alert name is the diagnosis) | hours — the fix was code (strict self-check, shipped Day 8) | manual (code) |
| 0006 | 6 | bad deploy | alert + **pipeline Verify** | ≈2 min | ≈0 (the deploy annotation) | ≈3 min | **pipeline** (auto-rollback) |
| 0007 | 8 | fraud dependency | alert → **ticket** (first) | ≈2 min | – (no responder notes; the ticket had names and times, not the cause) | ≈12 min | manual |
| 0008 | 9 | fraud dependency | alert → ticket | ≈2 min | 4 m 37 s, human, while reading the AI open-draft | ≈10 min | manual |
| 0009 | 10 | fraud dependency | alert → ticket + context | 156 s | **43 s, bot** (TTT 25 + TTH 18; right, medium confidence) | ≈8 min | manual |
| 0010 | 10 | bad deploy (build 19) | alert → ticket; pipeline had already rolled back | 156 s | 42 s, bot — right *event*, ranked second (half) | 0.3 min *before* the alert (pipeline) | **pipeline** |
| 0011 | 11 | fraud dependency | alert → ticket; **copilot asked at t+135 s** | 188 s | copilot **22 s** from the question = 157 s from the fault, **31 s before the alert**; bot right too | ≈8 min | manual |
| 0012 | 12 | crash-looping pod | alert → ticket | 264 s | – (signature) | ≈2 min after the fixture was removed | **auto** (tier 1; correctly reported *did not stick*) |
| 0013 | 12 | settlement crash | alert → ticket | 140 s | – (signature) | 15 min (alert window) | **auto** (tier 1, bounded retry succeeded) |
| 0014 | 12 | bad deploy, Verify skipped | alert → ticket → **proposal +28 s** | ≈190 s | – (signature: deploy 3.2 min before) | **389 s**; approve → healthy ≈60 s | **approved** (tier 2, one human decision, 35 s) |
| 0015 | 13 | untracked infra change (drift) | **none — human declared** at +8 m 18 s | none | ≈5 min (`terraform plan`, once it could see) | 51 min declared → repaired (48 of them fixing the tooling) | manual (`tf apply`) |
| 0015-b | 13 | real settlement failure mid-upgrade | alert → same ticket | 0 s | – (signature) | 10 min | **auto** (tier 1 re-run, 4 445 records) |
| 0015-fb | 13 | Fluent Bit killed by probe timeout ×10 | **human reading `RESTARTS`**, ≈5 h in | ≈5 h | 2 min (probe events) | fixed via Terraform; 0 restarts since | manual (code) |
| 0015-lat | 13 | three latency tickets overnight: activation ×2, egift (`EgiftStepSlow`) — while `133 --prove` built the Jenkins image and rendered five charts three times | alert → ticket, nobody looked (found in `kpis.py` the next morning) | ≈2–5 min | – (self-resolved; cause read off the timestamps next day: the lab's own tooling saturating the VM) | 2–4.6 min each | none |
| 0016 | 14 | game day 1, fault 1: partner email degradation (hand edit, 35 % of egift orders fail at `send_email`) | alert (`EgiftHighErrorRate`); the human saw the row red 30 s before the ticket | 4 m 17 s | **bot 2 m 03 s** (right: email step); human 5 m 44 s to the step, **7 m 05 s to the hand-made change** (invisible to the enrichment) | alert → resolved 10 m 27 s; fix → resolved 3 m 11 s | manual (remediator correctly declined, tier 3) |
| 0017 | 14 | game day 1, fault 2: settlement zero records (`silent` mode; the Day 8 self-check made it loud) | alert (`SettlementZeroRecords`, then `JobFailed` +2 min) — the human found it from a pod list, not the overview | 5 m 19 s from the env change; ≈2.5 min from the first affected run | human **1 m 41 s** (the job's own log line); bot +53 s | alert → resolved 18 m 28 s — **15 of them the alert's window**; fix → first clean run ≈19 s | manual cause fix + **auto** tier-1 retry succeeded (4 517 records) |
| 0017-a | 14 | **VM starvation** after the game: load average 48 on 4 CPUs (Splunk `archivebuckets` + the game's rollouts, AI calls, remediator Jobs + `up.sh`'s own Terraform render); the API server reset TLS handshakes; `docker restart` of the node hung, `kill` + `start` recovered it | `kubectl` errors while running the checkpoint — no alert (the alerts that *were* firing had been filed as kind noise) | – | ≈10 min (load average, `docker stats` inside the container, Splunk's job list) | ≈15 min | manual (node kill/start; Splunk capped at 1.5 CPUs; `up.sh`'s plan capped at 2 min) |
| 0017-b | 14 | **kube-scheduler: 70 restarts in 8 days**, `Leaderelection lost` — the lease renewal misses whenever the VM is starved; the "kind false positives" `KubeSchedulerInstanceUnreachable`/`TargetDown` since Day 1 were this | never — found in `up.sh`'s pod list after the reboot | 8 days | 2 min (`Last State` + the previous log) | – (self-heals each time) | none; follow-up: a restart alert for `kube-system`/platform namespaces, and stop routing those alerts to null |
| 0017-c | 14 | **otel collector: 112 restarts in 7 d 19 h**, exit 2 after ~30 s, no log line, every ~100 min since Day 4 | never — same pod list | 7.8 days | – (cause unknown: `--previous` log empty) | – | none; follow-up: capture the exit (`terminationMessagePolicy: FallbackToLogsOnError`, or a preStop dump) and the same restart alert |
| 0017-d | 14 | `IncidentBotDown` 15:33Z, 2.0 min — the bot itself gone during the post-game load; `INC-1788968015-f274` | alert (the monitor of the monitor, Day 8) | – | – | 2 min (self-resolved) | none — worked as designed; nobody was looking |
| 0018 | 16 | **the Day 10 dependency drill on EKS** (`FRAUD_SVC_DOWN=true`, 2 × t3.medium SPOT, images from ECR — zero application/manifest changes beyond the image line) | alert (`ActivationHighErrorRate`) — *fill from `tools/inc.py timeline <id>`* | … | bot: … (with the logs collector **not configured** — Splunk is on the laptop) | alert → resolved … | manual revert; remediator tier 3 (stayed out) |

**The week-over-week story** (the paragraph that summarises the project — numbers with
trend, no adjectives):

> **Detection.** Week 1: two of six incidents were found by a human watching a dashboard
> (0002, 0003), and one silent failure was caught only because a "good thing stopped
> happening" rule existed (0005). Week 2: every incident alerted within 2–4 minutes and
> became a ticket within 30 seconds — except the one that *cannot* alert, the untracked
> infrastructure change (0015), which is now caught nightly by the drift check, and the one
> nobody ticketed (0015-fb), which is the backlog item. **Diagnosis.** Week 1: ten minutes of
> manual querying the first time (0001), five minutes by Day 9 (0008). Week 2: the enriched
> ticket named the right cause at open time in 43 seconds (0009), the copilot found it 31
> seconds *before the alert fired* (0011), and for the three remediator signatures the
> diagnosis is the signature (0012–0014). **Recovery.** Day 6's manual rollback took
> minutes of a human at a keyboard; Day 12's took one decision — 35 seconds to read a
> proposal and type `approve` — and 389 seconds end to end; the two tier-1 re-runs took no
> human at all. **The game day (0016, 0017)** closed the fortnight the way it should: two
> faults, staggered, both alerted, both ticketed inside 50 seconds, the right cause on the
> first ticket in 2 minutes, both reverted by hand 11½ minutes after the first look, and the
> platform's own retry produced settlement's first clean run after the fix. What did not
> improve, and is the honest line: recovery is bounded by the alert's own window (15-minute
> `SettlementJobFailed`, 2-minute error-rate windows), not by the fix — the platform is
> healthy long before the ticket says so; and the thing the platform still cannot see is a
> change made outside the pipeline (0015's drift, 0016's `kubectl set env`) — the week-3
> backlog starts there.

## What to say about it

On 0009 the bot's time to diagnose was **43 seconds** from the first alert (25 s to the
ticket, 18 s to the hypothesis) and the diagnosis was right; the best human time on the same
fault was 4 m 37 s (0008) and the first time it was closer to ten minutes (0001). On 0010 the
clock reads 42 seconds but it does not count: the hypothesis named the right *event* — the
velocity-check deploy, not the fraud dependency — and put the true cause in its alternative,
but ranked the rollback first because the prompt described rollbacks as events. Same alert,
two different contexts, two different diagnoses pointing at two different, correct pieces of
evidence: that is the argument for enrichment. The honest caveat stands: the bot's diagnosis
only counts once a human confirms it, so the real metric is *time to a confirmed cause*, and
the AI moves the start of that clock — a responder now opens a ticket that already says
"probably this, here is why, medium confidence" — not the end.

Detection (TTD) has not moved and will not: 156–195 s is `for: 2m` plus a scrape and an
evaluation interval, the same since Day 3. Ticketing (TTT) is stable at 18–30 s
(`group_wait: 15s` plus the webhook). Context arrives in the same second the ticket opens
(TTX 0 s — all three collectors answered in under a second). The hypothesis lands 18–24 s
later, of which ~14 s is two AI round-trips (open draft, then hypothesis).

On 0015 the first column is the whole story: **TTD = none**. Fourteen incidents in, every
one had been opened by an alert within seconds; this one could not be, because the fault
*was* the disappearance of the signal the alert reads. A human noticed in eight minutes
because a human was looking; the honest projection for 3 AM is "until someone looks".
That is what the nightly drift check buys — not speed, but a ceiling. And the 59 minutes
from change to repair, 48 of them spent making Terraform actually see and actually apply
the fix, is the other lesson in the row: the tool you adopt to catch untracked change has
its own untracked assumptions, and the day you find them is the day you need it.

## Approve-to-recover (Day 12) next to the pipeline

| Path | What recovers production | alert → recovered | who decides |
|---|---|---|---|
| Day 6/10 pipeline Verify | 120 s wait + ~30 s `rollout undo`, **before any alert** — but only for releases that went through the pipeline | n/a (recovers before detection); deploy → recovered ≈ 2.5 min | nobody |
| Day 12 tier 2 | alert → PROPOSED (0–3 s) → a human runs `rem.py approve` (35 s in run 2) → `rollout undo` + verified (13 s) → windows clear (~5 min) | **389 s** alert → alert resolved; ~90 s alert → production healthy | one human, one command |
| Manual (Day 6 shape) | a human reads the dashboard, finds the deploy, types `rollout undo` | not recorded on Day 6 | one human, three steps |

Run 2 of the tier-2 drill: 28 s from the first alert to a proposal on the ticket, 35 s for the
human to read it and say yes, 13 s to roll back and verify — production was healthy about
90 s after the alert, and the alert itself resolved 389 s after it fired (its 2-minute window
plus Alertmanager's cycle: two clocks, both recorded). The honest caveat: the pipeline path
is faster *for deploys* because it does not wait for an alert; the tier-2 path covers what
the pipeline cannot — a release that slipped Verify, a config change, a rollback needed an
hour later — and turns "find the cause, decide, type" into "decide". Run 1 is kept next to
it: the rollback took the same 60 s, the verification was forbidden by one missing RBAC
verb, and the remediator said FAILED rather than guessing.

Cost line for the day: 6 tickets (2 drills × activation + egift, plus the invalid first run)
× 3 AI calls = 18 calls, **42,869 tokens**, 190 s of model time. At Sonnet list prices
(mostly input tokens, ~3–4k per record) that is roughly **$0.20 for the day** — less than
the coffee consumed waiting for alert windows. The valid drills alone: 29,154 tokens.
