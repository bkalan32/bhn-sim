---
id: kb-007
title: Untracked infrastructure change — something stopped without an app error
services: [settlement, activation, egift, incident-bot, remediator]
symptoms:
  - a metric goes ABSENT rather than bad: SettlementStale / SettlementZeroRecords / ActivationNoTraffic with the services themselves healthy
  - Prometheus targets missing (a ServiceMonitor, a Pushgateway, a scrape config gone) — the dashboard panel shows No data, not red
  - no deploy annotation, no pod restart, no app error in the logs
  - terraform plan against infra/local shows DRIFT (a Helm value, a release, a namespace label changed by hand)
discriminating_checks:
  - "./infra/local/tf.sh plan -detailed-exitcode   (exit 2 = the platform layer is not what the code says; the plan names the resource)"
  - "Prometheus: up == 0, or count by (job)(up) compared with yesterday; ./scripts/13-verify-scrape.sh"
  - "kubectl -n monitoring get servicemonitor,podmonitor; helm list -A   (what exists vs what the repo says should)"
  - "Jenkins infra-drift-check (nightly): the last run's console is the audit trail"
fix: Re-apply the code (./infra/local/tf.sh apply) — Terraform restores the declared state; then find who changed it and why it did not go through a PR. Never fix drift by hand: that is a second drift.
tier: 3
learned_from: [INC-0015]
---
Notes: INC-0015 (Day 13): settlement's metrics silently stopped because the Pushgateway
release was changed outside Terraform; nothing was "down", a panel just went empty. The
absence of a signal is the hardest incident class to detect — it is why the SettlementStale
rule exists and why up.sh runs a plan every morning. The drift check job (Day 13) turns
this from a Sunday surprise into a Monday email.
