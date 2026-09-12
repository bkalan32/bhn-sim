---
id: kb-005
title: Settlement runs but reconciles nothing — silent failure, zero records
services: [settlement]
symptoms:
  - SettlementZeroRecords firing (settlement_records_processed pushed as 0)
  - since Day 8 the job REFUSES to call it success: SettlementJobFailed joins ~2 min later, the pod exits 2 with "refusing to report success: zero records"
  - settlement_last_success_timestamp not advancing; the job's own log says level=ERROR (no app.status=error field — the logs collector misses it)
  - before Day 8 (INC-0005) the job exited 0 and only SettlementZeroRecords fired: a "success" that reconciled nothing
discriminating_checks:
  - "Prometheus: settlement_records_processed = 0 and settlement_last_run_status = 0 — the SAME for a crash (kb-004) since Day 8; the metrics do not discriminate, the log line does (INC-0021)"
  - "kubectl -n payments logs job/<newest settlement job> | grep -E 'records|refusing'   (the job names its own reason)"
  - "kubectl -n payments get cronjob settlement -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}' | grep -o 'SETTLEMENT_FAIL_MODE[^}]*'   (silent = the lab's knob; in a company: an empty upstream extract, a wrong date window, a schema change)"
  - "Grafana annotations / recent_deploys settlement: was the CronJob changed outside the pipeline?"
fix: Find why the input was empty (upstream extract, window, config) and re-run; the remediator's automatic re-run (tier 1, on SettlementJobFailed) fails for the same reason until the cause is fixed — its FAILED note quotes the reason onto the ticket, then one retry after 180s succeeds if a human fixed it in time.
tier: 1
learned_from: [INC-0005, INC-0017, INC-0021]
---
Notes: The two-signal design (Day 5/8): the metric says zero, the job says failed. In the
Day 14 game day the human found it from an Error pod in a pod list, not from the overview
— the settlement row on the dashboard was red and nobody looked. The alert description
still carried Day 5's "Succeeded, settlement complete" wording and the AI quoted it as
fact (Eval 6b) — fixed in k8s/alerts.yaml; do not trust description text as measurement.
