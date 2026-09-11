# Day 17 — Corrections Log

Source: `day17newrelicknowledgebase.pdf` ("chart names and free-tier limits verified on 29
August 2026") · Built 11 September 2026; nri-bundle version checked on artifacthub that day.

---

## [BUG] B1 — "Run the guided-install command it generates"

**Guide, Step 1.** The New Relic UI generates a `helm upgrade --install … --set
global.licenseKey=<your key> …` one-liner. Two faults, one of them a Day 13 regression:
the **license key sits in the command** (shell history, the terminal scrollback, a screen
share, a Jenkins log if you ever automate it), and the release is installed **by hand on
the platform layer Terraform has owned since Day 13** — the PDF itself says two paragraphs
later that changing it by hand would be "Day 13's drift lesson ignored", then tells you to
do exactly that. Also unpinned: whatever chart version is newest that day (Day 8).
**Substitute:** `helm_release.newrelic` in `infra/local/releases.tf`, version pinned in
`chart-versions.auto.tfvars` (8.0.24), values in `k8s/newrelic-values.yaml`, the key in
`secret/newrelic-license` referenced by name (`global.customSecretName`) — stored by
`170-newrelic-secret.sh` with `read -s`, verified by a single Metric API POST, in git and
state nowhere.

---

## [BUG] B2 — "Enabling log forwarding sends every container log … fine for the lab"

**Guide, Step 1.** Day 3 B4, again: the guided install's logging component tails
`/var/log/containers/*.log` — every pod on the node including New Relic's own agents, the
whole monitoring stack and Fluent Bit (a second feedback loop). "Fine for the lab" is the
sentence that precedes an ingest bill; the PDF's own point is to be the person who noticed
the switch. **Substitute:** `newrelic-logging.fluentBit.path:
/var/log/containers/*_payments_*.log` — the payments namespace only, as Splunk and CloudWatch
already get.

---

## [BUG] B3 — Two kube-state-metrics

**Guide, Step 1.** The guided install enables the bundle's own `kube-state-metrics`;
kube-prometheus-stack already runs one. Two KSMs is two full watches of every object on the
API server, on a 4-CPU VM that Day 14 showed thrashing. The chart's *default* is off, and
`nri-kubernetes` discovers an existing KSM by its `app.kubernetes.io/name` label — kps's
qualifies. **Substitute:** `kube-state-metrics.enabled: false`, `depends_on = [helm_release.kps]`.

---

## [BUG] B4 — Remote write without the keep-list, then "be proud of it" after the 413

**Guide, Step 2 and troubleshooting.** The remote-write block ships **every** series
Prometheus holds — kube-state-metrics, node-exporter, cAdvisor, the operator's own; tens of
thousands — and the troubleshooting note says to add a `writeRelabelConfigs` keep-list
*after* New Relic rejects it with 413/429. A hosted platform bills per series and per
sample; the keep-list is not a fix for an error, it is the design. **Substitute:** the keep
regex from the first apply (`activation_.*|egift_.*|settlement_.*|.*:health_score|
activation:.*|platform:.*|up|ALERTS`) — `171 --status` prints the kept series count next
to the total. And the block lives in `k8s/kps-values-newrelic.yaml`, layered by the kind
root only: it references a Secret that does not exist on EKS, and a remoteWrite whose
secret is missing leaves Prometheus unable to mount (Day 16 B12's cousin).

---

## [BUG] B5 — "Within a few minutes the cluster explorer shows your nodes" — the only proof offered

**Guide, Steps 1–2.** Confirm-in-the-UI, Day 15 B6's pattern. The sender knows whether the
receiver accepted: Prometheus exports `prometheus_remote_storage_samples_total`,
`_samples_failed_total`, `_samples_pending` per remote URL. `171 --status` reads them
through the API proxy — zero succeeded and failed climbing is a wrong key (401) or a missing
keep-list (413) before you open a browser; and `178` requires succeeded > 0. The agents
get the same treatment (pod status + a `licen` grep of their logs in the troubleshooting).

---

## [BUG] B6 — The KB entry template has no `tier`

**Guide, Step 5.** The template's `fix:` line says "Tier 3" in prose. The remediator has a
tiered policy (Day 12, `docs/remediation-policy.md`) and the incident bot's hypothesis is
asked to state "the team's prior answer" — that needs a field a program can read, not a
word in a sentence. **Substitute:** `tier: 1 | 2 | 3` is required; the parser rejects
anything else.

---

## [BUG] B7 — "Twenty lines, no vector database" — and no parser

**Guide, Step 6.** "Read all kb/*.md front matter" — with what? The bot's image carries
fastapi, uvicorn and prometheus-client; no YAML library. Adding PyYAML for seven files is
a dependency for a parser you can write in forty lines, and a hand-written parser that
accepts **only** the template's shape (`key: value`, `[a, b]`, `- item`) is the
validation the PDF's "strict template so both humans and code can rely on the shape" needs
and never builds. **Substitute:** `services/incident-bot/kb.py` — parser, scorer, prompt
renderer — shared by the bot and the copilot (one truth), covered by
`tests/test_kb.py` (a malformed file fails the pipeline's test stage), validated by `172`
before the ConfigMap ships.

---

## [BUG] B8 — Symptom scoring by naive overlap matches the look-alike on its negation

**Guide, Step 6.** "Score by overlap between the query terms and symptoms." The first cut
did exactly that and tied kb-001 (fraud) with kb-002 (bad release) on the query
*ActivationHighErrorRate fraud_service_timeout* — because kb-002's symptoms say "**not**
fraud_service_timeout". A discriminator against, scored as a match for. **Substitute:**
negated words (`not X`, `never X`, `rather than X`) are dropped before tokenising, and
alert names / `app.reason` values weigh 3× a generic noun. Every pattern now ranks first
on its own words with the documented look-alike second — which is what the prompt wants.

---

## [BUG] B9 — `nri-metadata-injection`: a mutating webhook for an APM agent we do not run, and a plan that can never be clean

**Guide, Step 1 (found on the first apply).** The bundle's default enables
`nri-metadata-injection`: a **MutatingWebhookConfiguration** the API server calls on every
pod create, cluster-wide, to inject New Relic attributes into APM agents. There is no APM
agent in any of our images — the webhook is a hop in every scheduling decision for nothing.
Worse for Day 13: its chart generates a TLS cert in a post-install Job and patches the
`caBundle` into the webhook, then `lookup`s it on the next render; the helm provider's
dry-run (the `manifest` experiment) renders an empty bundle, the live object has one, and
Terraform reports *"Provider produced inconsistent result after apply"* — release tainted,
next plan a replace, same error again. The first apply hit the same wall on the logging
chart's ClusterRole (a first-install render difference), which the untaint cleared; the
webhook one recurs forever. **Substitute:** `nri-metadata-injection.enabled: false`. The
lesson is the Day 13 one: anything a chart decides at install time from cluster state
cannot be planned, and a hosted vendor's "harmless default" is a webhook in your API
server's critical path.

---

## [BUG] B10 — The pipeline left the bot down and said "nothing was deployed"

**Found on the first Day 17 deploy (build 34).** `Jenkinsfile`'s post block set `DEPLOYED`
only *after* `rollout status` succeeded, so a rollout that never became ready — the new pod
crash-looping — fell through to *"Build failed before Deploy — nothing was deployed,
nothing to roll back"*. But the apply had happened, and under `strategy: Recreate` the old
pod was already gone: the incident bot was **down for 20 minutes** with the pipeline
reporting there was nothing to undo. **Substitute:** `APPLIED` is set the moment the
manifest is applied; a failed rollout on a Deployment now `rollout undo`s, waits for the
previous revision to be ready, annotates the change-cause and the Grafana timeline. A
pipeline's rollback must key on *what the cluster has*, not on which stage printed OK.

---

## [DESIGN] D1 — How the KB reaches the bot: a ConfigMap, not the image

The PDF does not say. Baking `kb/` into the image means a rebuild and a deploy to fix a
typo in a symptom. A ConfigMap (`172-kb.sh`, `kubectl create configmap --from-file=kb/`)
mounted read-only at `/kb`, **optional** in the manifest, updates in place — and the bot
starts without it and says so on `/ai` (`kb.ok=false`), because the KB improves diagnosis
and must never gate intake (the AI rule, applied to the AI's input).

## [DESIGN] D2 — The prompt records what it was offered

`ai_meta.hypothesis.kb_matches` on the record lists the entry ids (with scores) the bot
put in the prompt. Without it, "the hypothesis did not cite kb-001" cannot be graded:
was it offered and ignored (a model failure) or never offered (a retrieval failure)? Eval
8 needs the distinction; `173` prints it before the hypothesis.

## [DESIGN] D3 — Ten lines, with an evidence table under them

`docs/newrelic-notes.md` ships as a template with the ten numbered lines empty and a
table underneath — time to the three panels in each system, alert → inbox, what each
system *does* with the alert, portability, cost model, maintenance. Opinions with a table
under them survive a meeting.

## [NOTE] N1 — INC-0019

The PDF logs the KB drill as INC-0018; that was Day 16's EKS drill. The Day 17 drill is
**INC-0019**, graded in Eval 8 against INC-0009 (no KB) and INC-0018 (no KB, no logs).

## [NOTE] N2 — The New Relic dashboard and alert stay manual, on purpose

Both could be made through NerdGraph with a User key. The PDF's Step 3 is a *comparison*
exercise — how long does the hosted UI take versus `09-grafana-dashboards.sh` — and
automating it would erase the measurement. The evidence row in `newrelic-notes.md` is
where the minutes go.

## [NOTE] N3 — kps restarts Prometheus and may replace Grafana

The remote-write overlay is a Prometheus change; the kps upgrade restarts Prometheus (a
minute of gap in every rate panel) and can replace Grafana's pod — which forgets its
service-account tokens (Day 13). `171` runs `100 --check` afterwards and re-mints if
needed. Not a bug; a thing to expect.

---

## [NOTE] N4 — My bug, kept: the counters were named from a 2019 Prometheus

The first cut of `171 --status` and `178` read `prometheus_remote_storage_succeeded_samples_total`
and `_failed_samples_total` — the names every remote-write blog post uses, removed in
Prometheus 2.20 (2020). kps 88 ships Prometheus 3.x, so the proof printed "no data" for
samples that were in fact landing; `_samples_pending` (unchanged) was the only live number.
Now `prometheus_remote_storage_samples_total` / `_samples_failed_total` / `_samples_retried_total`.
The lesson is Day 5's, pointed at me: a metric name is an interface with a version.

---

## [NOTE] N5 — My bug, kept: the image never had `kb.py`

`services/incident-bot/Dockerfile` copies files by name (`COPY app.py ai.py enrich.py ./`)
and the first Day 17 build shipped without `kb.py`: `ModuleNotFoundError` at import,
CrashLoopBackOff, B10 above. The tests passed because pytest runs from the source tree,
not the image — a green test stage proves the code, not the artifact. The Verify stage
would have caught it; the rollout never got that far. Fixed by adding the file, and by the
rollback above. The durable lesson: an explicit COPY list is a second place a new module
must be declared, and `--previous` logs are the first thing to read on a crash-loop.

---

## Verified as correct

`lowDataMode` and the ingest framing; remote write from the existing Prometheus as the
instructive path (one scraper, two destinations); the NRQL example; the ten-lines format;
the KB's front-matter design and the seven patterns to write; "sourced from your own INC
write-ups is the only honest way a KB gets written"; the copilot tool + one prompt line;
the bot injection at hypothesis time; "same model, same incident, better answer" as the
thesis; the maintenance rule and where it goes.
