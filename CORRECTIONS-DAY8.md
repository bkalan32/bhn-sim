# Day 8 — Corrections Log

Source: `day8alertroutingincidentbot.pdf` · Verified 4 September 2026 against the running lab
(kube-prometheus-stack 88.6.2, Alertmanager 0.28, kind v0.33.0).

---

## [BUG] B1 — The PDF's routing turns every kube-system false positive into a permanent ticket

**Guide, Step 2:** `route: { receiver: incident-bot, routes: [ {severity = critical → incident-bot} ] }`

The default receiver is the bot and there is no `null` route. Your kind cluster carries
**nine** always-firing kube-prometheus-stack alerts (`KubeSchedulerDown`,
`KubeControllerManagerDown`, `KubeProxyDown`, `etcd*`… — Day 3 screenshots) plus
`Watchdog`, which fires forever *by design* as Alertmanager's heartbeat. One minute after the
upgrade the bot would hold ten open incidents that never resolve, `incidents_open` would read
10 on the overview, and the KPI panel would be meaningless before the first real drill.

**Substitute:** default receiver `"null"`; only alerts carrying one of *our* `service` labels
route to the bot; `Watchdog` explicitly to `"null"`. The overview's alert panels already
scope the same way (Day 7).

---

## [BUG] B2 — The severity sub-route splits one outage into two incidents

The PDF's design note says grouping "means the fraud outage's error alert and latency
alert land in one incident, not three." Its config does the opposite. Alertmanager's
`groupKey` embeds the **route** that matched. `ActivationHighErrorRate` (critical) matches
the sub-route; `ActivationHighLatency` (warning) falls through to the default route.
Different routes → different group keys → two webhooks → the bot, keyed on `groupKey`,
opens **two** incidents for one fault.

Two fixes, both applied:

1. **No severity sub-route.** One route for our services, `group_wait: 15s` for everyone.
   The 10s-vs-30s distinction buys nothing in a lab and fragments tickets in production.
2. **The bot joins on `service`, not `groupKey`** (`INCIDENT_JOIN=service`, the manifest
   default). It still records every group inside the incident and only resolves when *all*
   of them have resolved — so even if you reinstate a severity route, you get one ticket.
   Set `INCIDENT_JOIN=group` to see the PDF's behaviour.

---

## [BUG] B3 — `emptyDir` loses every incident on every deploy

**Guide, Step 1:** "add an emptyDir volume mounted at /data … Bot loses incidents on
restart: acceptable for the lab."

It is not acceptable *for this series*. Day 9 ships `incident-bot:0.2` and Day 10 ships
`0.3` through the pipeline; each rollout replaces the pod, and each replacement empties the
volume. You would write `docs/ai-eval.md` about incident IDs that no longer exist, twice.
kind's default StorageClass (`standard`, local-path) makes a **PersistentVolumeClaim** one
stanza. `strategy: Recreate` because a directory is not a database — two pods must never
write it at once. Both in `k8s/incident-bot.yaml`. `fsGroup: 10001` so the non-root
container can write the mount.

---

## [BUG] B4 — `max(a["severity"] ...)` is a string comparison

`max("critical", "warning")` → `"warning"` — `w` > `c` alphabetically. Every incident the
PDF's bot creates is a *warning*. Ranked explicitly (`critical > warning > info`).

---

## [BUG] B5 — `helm upgrade` without `--version` can upgrade the whole stack

**Guide, Step 2:** `helm upgrade kps prometheus-community/kube-prometheus-stack -n monitoring -f k8s/kps-values.yaml`

Without `--version`, Helm takes the newest chart in your local repo cache. After any
`helm repo update` (Day 5's Pushgateway script runs one) that can be a major version bump —
new CRD schemas, changed defaults, a Grafana upgrade — smuggled in under "point Alertmanager
at a webhook." `81-alertmanager-route.sh` reads the installed version from `helm list` and
pins it, and adds `--reuse-values` so nothing else you have set is reset to chart defaults.

---

## [BUG] B6 — "Ship both through the pipeline" does not work as written

The Day 6 Jenkinsfile (the PDF's own) has `choices: ['activation', 'egift']`, runs
`kubectl rollout status deployment/…`, and verifies against `activation_requests_total`.

- `settlement` is a **CronJob**: no rollout, no `rollout undo`, no request metric.
- `incident-bot` is a Deployment with **no request metric**: Verify would read `nodata`,
  declare the deploy failed, and roll it back every time.

The Jenkinsfile now carries `KIND` and a per-service `METRIC`. CronJobs are verified by
*running a job* and rolled back by re-applying the previous image (recorded before the
deploy). Metric-less deployments are verified by staying Ready for 30s with zero container
restarts. Two lessons from making this work: "did the deploy succeed?" has a different
answer per workload shape, and a CronJob has no rollback unless you *record* what was
running — Kubernetes will not remember for you.

**Jenkins quirk:** parameter definitions live in the Jenkinsfile and are refreshed *after* a
build runs with the new file. The first "Build with Parameters" after this change still
shows only `activation | egift`. Run one build (activation, "routine release") — or click
*Build Now* and let it fail at Test — and the dropdown updates.

---

## [BUG] B7 — The amount-mix test snippet uses `client` (TestClient) again

Same as Days 2 and 6: `client.post(...)` needs `fastapi.testclient` → `httpx`, which broke on
Day 2. Our suite already had this test (added Day 7, env-gated). Day 8 **removes the gate**:
a safety net that only exists when someone remembers an env var is not a safety net.
`53-bad-deploy.sh apply` now *fails* to commit the bad build (correct), unless
`FORCE_BAD_DEPLOY=1` — Day 10's Drill B uses that deliberately.

---

## [BUG] B8 — The Helm upgrade wipes every UI-imported Grafana dashboard

Not in the PDF, found live. The chart's Grafana has no PersistentVolume; UI imports live in
SQLite inside the pod; `helm upgrade` re-stamps config checksums and rolls the pod. Four
dashboards gone in Step 2 of the PDF's day, and it would happen again on every future
upgrade or node restart. `09-grafana-dashboards.sh` provisions `dashboards/*.json` as
ConfigMaps (label `grafana_dashboard: "1"`, `${DS_PROMETHEUS}` resolved to the provisioned
uid) — the same mechanism Day 4 used for the Tempo datasource, which is why *that* survived.

---

## [NOTE] N1 — Alertmanager redacts webhook URLs in its status API

`/api/v2/status` prints the live config with every `url:` under `webhook_configs` replaced by
`<secret>`. The first version of the Day 8 checkpoint grepped for the URL and reported "not
routing" while a real incident was being ticketed. Check for the receiver *name*
(`name: incident-bot`), or better, for the effect (an incident arriving). Anything a config
schema marks as a secret will be invisible through the API — verify by behaviour.

---

## [DESIGN] D1 — `group_by: ["service"]`, and why

The PDF offers `["alertname", "service"]` or `["service"]` and says "pick an opinion."
Opinion: **one incident per service outage.** A responder on the bridge wants a ticket that
says "activation is broken," with the alert names *inside* it, not three tickets to
cross-reference. `ActivationHighErrorRate` and `ActivationErrorBudgetBurnFast` for the same
fault are one problem. The cost: an unrelated warning on the same service during an incident
attaches to it. In this lab that trade is clearly right; in a company with a 40-alert service
you might group by `[service, team]` or `[service, component]`. The point is that it *is* a
choice and you can defend it.

---

## [DESIGN] D2 — Backlog #3 (`EgiftHighLatency`) done today, not left open

The PDF's Day 8 clears two backlog items. The week-1 review had three. The third — eGift has
no latency alert, so INC-0002 and INC-0003 were both detected by a human — costs three rules
(`EgiftHighErrorRate`, `EgiftHighLatency`, `EgiftStepSlow` which names the slow step). Day
7's own overview screenshot showed eGift p95 at 2.4s with nothing firing. If
`EgiftHighLatency` opens an incident within minutes of the upgrade, that is not a false
positive; that is the gap being closed.

---

## [ADDED] A1 — Things the bot has that the PDF's does not

- Tests (`services/incident-bot/tests/`), run by the pipeline's Test stage.
- `first_alert_at` from Alertmanager's `startsAt`: when Prometheus saw the condition, not
  when the webhook arrived. Day 10's time-to-detect column depends on it.
- ISO timestamps next to every epoch. The PDF's records are `1788556435.68` all the way
  down; Day 9 asks a language model to reason about that.
- `/readyz` refuses traffic when `/data` is not writable, so Alertmanager retries instead
  of losing the webhook. `alertmanager_webhooks_total` so "is anything arriving?" is a panel.
- `POST /incidents/{id}/note` now (the PDF adds it on Day 9) and `DELETE` for the smoke test.
- `tools/inc.py` — list / show / timeline / note / delete through the API-server proxy.
  No port-forward, no pinned pod.
- `IncidentBotDown` alert. Monitor the monitor.

---

## Verified as correct

- "Build the ticketing layer yourself; every alert-to-ticket integration you meet later is
  a variation." True, and the reason to do it this way.
- `groupKey` as the natural join key, `send_resolved: true` to auto-close, the append-only
  timeline, the bot exporting its own metrics. All right in principle; B2 is about what the
  group key *contains*, not about using it.
- The route settings as alert-fatigue controls, and the meaning of `group_wait`,
  `group_interval`, `repeat_interval`. Right.
- The secret-decode command for checking the generated Alertmanager config, including the
  `\.` escaping in the jsonpath. Right — the script uses it.
- Incidents-per-day as a core operational KPI, and `increase(...[24h])` surviving counter
  resets. Right.
- The layered-defence argument for settlement: self-check *and* alerts. Right, and worth
  saying in an interview.
