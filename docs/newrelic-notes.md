# New Relic vs the self-run stack — ten honest lines (Day 17, Part A, Step 3)

Written after wiring the same cluster and the same business metrics into New Relic
(`scripts/171-newrelic-up.sh`: the nri-bundle agents as a pinned Terraform release,
Prometheus remote-writing a keep-list of business series), rebuilding the Day 2 golden-signal
panels as a New Relic dashboard, one alert condition (activation error rate > 10 %, to
email), and firing one short fraud drill into both systems. Teams argue this trade
constantly; the point of the ten lines is to arrive with an opinion that has evidence under it.

## What was faster hosted

1.
2.
3.

## What you lose

4.
5.
6.

## What only the self-run stack has (and why it stays)

7.
8.

## When a company reasonably runs both

9.
10.

## Evidence

| | Self-run (Prometheus/Grafana/Splunk/Tempo) | New Relic |
|---|---|---|
| time to the three golden-signal panels | Day 2: ~1 h incl. learning PromQL; now: `09-grafana-dashboards.sh`, seconds | *(minutes to click, minutes to write NRQL — fill in)* |
| alert → a human's inbox | Alertmanager → the bot (Day 8); email never wired | *(the condition + email channel — minutes; fill in)* |
| the fraud drill, seen in both | alert at … , ticket at … | *(NR alert opened at …; fill in)* |
| what the platform does with the alert | opens a ticket, enriches it, drafts a hypothesis, the remediator judges tier | notifies |
| recording rules / health scores / SLO burn | `k8s/alerts.yaml`, portable PromQL | not portable; remote write ships their *results*, not their definitions |
| cost model | the laptop; on EKS ~$0 above the nodes | per GB ingested (100 GB/mo free): the keep-list in `kps-values-newrelic.yaml` is the control |
| maintenance | yours: Day 13's drift, Day 14's restarts, Day 15's Fluent Bit | theirs |
| logs | Splunk (kind) / CloudWatch (EKS) | one more place; payments namespace only, by choice |
