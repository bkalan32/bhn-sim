# New Relic vs the self-run stack — ten honest lines (Day 17, Part A, Step 3)

Written after wiring the same cluster and the same business metrics into New Relic
(`scripts/171-newrelic-up.sh`: the nri-bundle agents as a pinned Terraform release,
Prometheus remote-writing a keep-list of business series), rebuilding the Day 2 golden-signal
panels as a New Relic dashboard, one alert condition (activation error rate > 10 %, to
email), and firing one short fraud drill into both systems. Teams argue this trade
constantly; the point of the ten lines is to arrive with an opinion that has evidence under it.

## What was faster hosted

1. The cluster view was there before I had typed anything: agents applied at 18:15Z, and by 18:20Z New Relic showed the node, 45 containers, 37 pods, the settlement CronJob with its schedule, and an activity stream that had already noticed one of its own pods failing a probe — Grafana's overview took me most of Day 2.
2. Logs with parsed JSON fields at 18:19Z with no Fluent Bit config on my side beyond a path — the `stats count by app.reason` search I wrote on Day 3 is a NRQL `FACET` that took me one attempt.
3. NRQL does error % in one query (`filter(...) / rate(...)`) where Grafana needs two queries and a transform; the three panels were minutes of typing, not an afternoon — and the vulnerability banner on their own agent image and the pod-unhealthy event came free.

## What you lose

4. Two minutes and twenty seconds of alert latency, structurally: Prometheus fired at 18:56:40Z, their issue opened at 18:59Z on the same samples, because remote write is a queue and their condition needs a delay window for late data — my alerts evaluate my own scrapes and need none.
5. The AI summary and 'potential causes' panels are greyed out behind a paid tier; the bot attached context and a hypothesis to the same incident 23 seconds after the ticket, and I wrote that on Day 9.
6. Everything is a bill: 48 098 series in Prometheus, 205 sent, payments logs only — the keep-list and the log path are not tidiness, they are the cost control — and a default they ship (a mutating webhook on every pod create, for APM agents I do not run) sat in my API server's admission path and could not be planned by Terraform until I turned it off.

## What only the self-run stack has (and why it stays)

7. The response is mine: ticket, enrichment from three sources, a hypothesis with a knowledge base behind it, a remediator with a tiered policy — New Relic *notifies*; what happens next is a person or a Slack channel unless you pay for their version of each of those.
8. The definitions are code: recording rules, health scores, SLO burn rates and alert thresholds in `k8s/alerts.yaml`, reviewed in a pull request, planned by Terraform; remote write ships their *results* to New Relic, and the alert condition I built by hand in their UI is already the Day 13 drift I spent a day removing.

## When a company reasonably runs both

9. One scraper, two destinations is the honest shape: Prometheus scrapes once, Grafana and the bot alert on it, New Relic gets the business series for a shared view that a product manager or a partner team can read without PromQL, and the cluster explorer for 3 AM 'what does it look like'.
10. Both, with a rule about which one is authoritative for what: alerting and automation stay on the self-run stack (closer to the data, no delay, no per-series bill), the hosted platform owns the cross-team view and the things I do not want to maintain — and the moment a team lets the hosted alert be the pager, they have accepted a 2-minute tax and a bill that grows with success.

## Evidence

| | Self-run (Prometheus/Grafana/Splunk/Tempo) | New Relic |
|---|---|---|
| time to the three golden-signal panels | Day 2: ~1 h incl. learning PromQL; now: `09-grafana-dashboards.sh`, seconds | ~15 min of NRQL by hand: request rate and error % first try; p95 — `percentile()` on the remote-written histogram did not apply, the `_bucket` series FACET `le` drew the buckets, not a p95 |
| alert → a human's inbox | Alertmanager → the bot (Day 8); email never wired | condition + destination (verified email) + workflow: ~10 min of clicks; a 2-min delay window is mandatory for remote-write data |
| the fraud drill, seen in both | alert at 18:56:40Z, ticket at 18:57:06Z (INC-1789153026-7443; context + hypothesis by 18:57:29Z) | NR alert opened at 18:59Z (issue 'ActivationHighErrorRate (NR)', email notified) — **2 m 20 s behind** on the same samples; first run (18:47–18:49) was under its 2-min `for` and never fired |
| what the platform does with the alert | opens a ticket, enriches it, drafts a hypothesis, the remediator judges tier | notifies |
| recording rules / health scores / SLO burn | `k8s/alerts.yaml`, portable PromQL | not portable; remote write ships their *results*, not their definitions |
| cost model | the laptop; on EKS ~$0 above the nodes | per GB ingested (100 GB/mo free): the keep-list in `kps-values-newrelic.yaml` is the control |
| maintenance | yours: Day 13's drift, Day 14's restarts, Day 15's Fluent Bit | theirs |
| logs | Splunk (kind) / CloudWatch (EKS) | one more place; payments namespace only, by choice; landed 18:19Z, ~4 min after apply |
| data arriving | scrape, 30 s | remote write: 13 344 samples accepted in the first 20 min, 14/s, 205 of 48 098 series (`171 --status`, Prometheus's own counter, not their UI) |
| the agents themselves | Prometheus: **47 restarts in 9 days**, nothing alerted (Day 14's 0017-b/c family; Day 18) | `newrelic-logging` restarted on a liveness 500 within its first minute — their activity stream said so before I looked |
| a plan that can never be clean | Day 13 B10 (Grafana's `lookup`) | `nri-metadata-injection` patches its own caBundle after install: "inconsistent result after apply" on every apply until disabled (B9) |
