# Day 18 — Corrections Log

Source: `day18alerthygienekpisdailyreport.pdf` ("verified on 29 August 2026") · Built 11 September 2026.

---

## [BUG] B1 — "Route the noisy defaults away from the incident bot" — they never reached it

**Guide, Step 2.** The PDF's expected finding is that `CPUThrottlingHigh`, `KubeMemoryOvercommit`
and friends are flooding the bot, and the fix is a `severity =~ "info|none"` route to null.
On this platform the default receiver has been `null` since Day 8 (CORRECTIONS-DAY8 B1):
only alerts carrying one of *our* `service` labels ever reach the bot, so the chart's rules
have produced zero tickets in eighteen days — the audit table's `tickets` column says so.
The noise was real but lived elsewhere: in Alertmanager's UI, in the copilot's
`firing_alerts` tool ("only infrastructure alerts"), and above all in **four rules that
fired continuously since Day 1** for components kind binds to localhost, hiding a real
scheduler problem for a week (Day 14, 0017-b). **Substitute:** the explicit null routes are
added anyway (visible, testable with `amtool config routes test`, and they sit above the
ticket route so a demoted alert that *also* carries a service label — the trap in the PDF's
own troubleshooting — still goes to null); the four permanent false positives are removed at
the **scrape** with the chart's own switches (A1), not routed; and the audit's real work is
in our fifteen rules (A2–A6).

---

## [BUG] B2 — "Apply via Terraform" — half of it is, half of it must not be

**Guide, Step 2.** The routing lives in `k8s/kps-values.yaml`, which *is* Terraform
(`helm_release.kps`, Day 13). The rules live in `k8s/alerts.yaml`, a `PrometheusRule` we have
applied with `kubectl` since Day 3 and that the EKS deploy (`163`) applies the same way;
moving it into the kps release would make every rule edit a Helm upgrade of the monitoring
stack and would tie our rules to the chart's lifecycle. **Substitute:** two layers, two
tools, on purpose — `181` applies both and says which is which.

---

## [BUG] B3 — The KPI "Incidents/week by service = `increase(incidents_created_total[7d])`"

**Guide, Step 3.** The bot's counter had no `service` label (Day 8) — the query the PDF
gives returns one number for the whole platform and cannot be split. **Substitute:** the
counter carries `service` from the Day 18 build (`CREATED.labels(service=…)`, the resolved
counter likewise; the Day 8 test updated), the dashboard panel is `sum by (service)`, and
until the new build is deployed the KPI comes from the records (`tools/kpis.py --summary`
does both and says which).

---

## [BUG] B4 — "Alert precision = alerts that became real incidents / all alerts" — with no definition of "all alerts"

**Guide, Step 3.** Alertmanager keeps no history and Prometheus's `ALERTS` is a time series,
not a list of events; "all alerts" has to be defined or the number is unfalsifiable.
**Substitute:** precision is computed over alert **names** — names that reached a ticket ÷
names that fired at all in the window (`count by (alertname) (count_over_time(ALERTS{alertstate="firing"}[7d]))`,
Watchdog excluded). Coarse by design (a name is the unit the audit judges), and the script
prints the *noise* list next to the number, because a silenced real alert would raise
precision just as honestly as a removed false one — the list is what keeps it honest.

---

## [BUG] B5 — "Drift-check status from the Jenkins job"

**Guide, Step 4.** Reading another job's result needs an authenticated Jenkins API call; the
lab has never stored a Jenkins credential anywhere (the password is prompted, Day 6), and a
4-hour-old verdict (03:00 job, 07:00 report) is not "drift status". **Substitute:** the
report job **plans first** — the same 90-second `terraform plan -detailed-exitcode` as
`Jenkinsfile.drift`, same env — and hands the verdict to the script as `DRIFT_STATUS`.
Locally the script reports *no data* unless `--plan` is given, and says why.

---

## [BUG] B6 — "POST it to the incident bot as a note-style record" — a note on what?

**Guide, Step 4.** Notes attach to incidents; a daily report on a quiet day has no incident
to attach to. **Substitute:** a ten-line `/reports` store on the bot (`POST /reports`,
`GET /reports`, `GET /reports/{day}`), atomic writes like the incidents, keyed by day (or
`day-slug` for a re-run after a drill), holding the text **and the data the model was
given** so a grader can trace every number a week later.

---

## [BUG] B7 — "Log the day's routing drill as INC-0019"

INC-0019 is Day 17's knowledge-base drill. A demoted alert that ticketed live would be
**INC-0020**; the probe ticket `RoutingProbe{service=smoke-test}` that `181` opens on
purpose is the verification record and is not numbered.

---

## [BUG] B8 — Found in a build log: the pipeline's Grafana annotations have failed silently since Day 13

**Ours, not the PDF's.** Deploy #37 (the remediator) printed `secrets "kps-grafana" not found …
WARNING: Grafana annotation failed (rc=22) — deploy continues`. Day 13 B10 moved Grafana's
password to `secret/grafana-admin`; `Jenkinsfile`'s `grafanaAnnotate` kept reading the
chart's secret. Consequence, for five days: **no pipeline deploy or rollback was annotated**,
so the bot's *deploys* collector (Grafana annotations are its source of truth for "what
changed", Day 10) saw none of them, the remediator's tier-2 `post-deploy-errors` signature
(deploy within 30 min) could not have matched a real bad release, and every hypothesis's
"no deploy in 6 h" was true for the wrong reason. Nothing alerted, because the failure was a
line in a green build. **Substitute:** `grafana-admin` first, `kps-grafana` as fallback (the
same order as `lib.sh`), and the warning now shouts what the missing annotation *means*. A
build should not fail for it — a deploy that shipped is a deploy that shipped — but the
change-record gap is exactly the kind of silent failure the audit exists to find. Logged as
**0020-a** in `docs/ops-kpis.md` (found, not alerted; Day 14's 0017-x family); follow-up: an
alert on `grafana_annotations` absence after a `deploy-service` build, or the pipeline
posting the change to the bot directly as a second channel.

---

## [DESIGN] D1 — The judgments live in the script's map, the data in Prometheus and the bot

The PDF's table is written by hand. Ours is generated: `180` pulls every rule, its hours
firing in ten days and the tickets it produced, and joins the four judgment columns from a
map in the script — so the doc and the code cannot drift, and "edit the map, re-run" is how
a disagreement is recorded. The six decisions under the table are prose, with reasons,
because the PDF is right that undocumented alert changes are how noise comes back.

## [DESIGN] D2 — Four findings from yesterday, folded in as rules

The audit's best inputs were Day 17's: `ActivationErrorBudgetBurnFast` firing after the fix
(A3: no `for:`), `IncidentBotDown` delivered to the bot (A5: a tier-1 restart signature on
the remediator, which receives the same webhook), Prometheus's 47 restarts (A6:
`PlatformPodRestarting`, Day 14's ask), and a bot pod killed for starting slowly under load
(a `startupProbe`). An audit that only looks at the chart's rules misses the ones you wrote.

## [DESIGN] D3 — `amtool config routes test` before `amtool alert add`

The PDF fires a test alert at each route. A live synthetic that reaches the bot costs an
enrichment, two model calls and a ticket in the history; a dry route test costs nothing and
answers the actual question ("which receiver would this label set reach"). `181` runs twelve
dry tests — including the service-label trap — and then exactly two live ones, one per
receiver, that expire in two minutes.

## [DESIGN] D4 — The report's traceability check is code, not a grader's patience

`daily_report.py` extracts every number from the text and looks for it in the JSON it sent;
the list of misses is printed, stored with the report and written into its header. A
derived number (a sum, a delta the model computed) shows up here and is graded as the rule
violation it is. Eval 9's "every number traceable?" starts from that line, not from zero.

## [NOTE] N1 — The remediator's history is in memory

KPI 4 reads the remediator's `/actions` (200 entries, lost on restart) and its PromQL twin
reads a counter that resets with the pod. Both are honest about *recent* remediation and
wrong about "all time"; the definition in `docs/ops-kpis.md` says so. A durable store is a
follow-up, not a Day 18 task.

## [NOTE] N2 — A scheduled job on a laptop

`H 7 * * *` fires only if the laptop and Docker are awake at seven. `morning.md` step 4 fetches
the report and treats a 404 as the finding it is ("the brief did not run"), then runs it by
hand. In a company the scheduler is not a laptop; the failure mode ("no report today") is
the same and the Jenkinsfile's `post { failure }` says what it means.

## [NOTE] N3 — Model calls today: three or four

Run 1 (quiet), run 2 (after a drill), run 3 (the Jenkins job), plus the drill's own two
drafts. `MAX_TOKENS=520` and `temperature 0.1`; the 250-word cap is the last line of the
prompt because caps stated last survive best (the PDF's troubleshooting note is right).

---

## [NOTE] N4 — Mine, kept: the fetch overwrote the quiet run; a truncated brief looked complete

Two tooling defects found by running it three times. (1) The plain date was both the local
run's file name and the scheduled run's store key, so `--fetch` after the Jenkins run
replaced run 1's file: the plain date now belongs to the scheduled run only, hand runs get
`-manual` (or `--day <slug>`), and `--fetch` refuses to overwrite a local run. (2) The first
report stopped mid-sentence at a 520-token ceiling with no RISKS and no NEEDS A HUMAN, and
nothing said so — the word cap held, the token cap did not, and "caps stated last survive
best" is true of words only. Now 900 tokens, a four-heading check, and a loud `TRUNCATED`
in the footer and the file (Eval 9's first row; `188` fails on a truncated current report).

---

## Verified as correct

The four-question interrogation; "route, don't delete" for chart rules you *could* scrape;
"write the decision and the reason"; static latency thresholds as the most common fatigue
source; the takeaway sentence; "resist a bigger table" (seven KPIs); the gather → constrain →
draft shape on a schedule; the `PROMPT` text (used nearly verbatim, with three rules added:
every number must appear in the data, quiet days are reported quiet, no advice beyond the
data); "a boring day must produce a boring report" as the eval's centre; the cron trigger
and Jenkins as the lab's scheduler; caps stated last.
