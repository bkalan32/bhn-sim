---
id: kb-002
title: Bad release — a new build raises the error rate
services: [activation, egift]
symptoms:
  - ActivationHighErrorRate and/or ActivationErrorBudgetBurnFast within minutes of a deploy
  - a deploy annotation for the service 0-30 minutes before the first alert
  - a NEW app.reason dominates (velocity_check_blocked in INC-0006/0010/0014), not fraud_service_timeout
  - p95 latency unchanged (the requests fail fast, they do not wait)
  - the pipeline Verify stage may have auto-rolled back already (a rollback annotation seconds before or after the alert)
discriminating_checks:
  - "recent_deploys activation (Grafana deploy/rollback annotations, with minutes_before_first_alert): a deploy in the last 30 min is the lead; a rollback is EVIDENCE of a suspected deploy, never a cause"
  - "kubectl -n payments rollout history deployment/activation   (which build is live; the change-cause names the PR)"
  - "Splunk: app.service=activation app.status=error | stats count by app.reason, app.version   (the bad reason appears only on the new version)"
  - "kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].image}'   (is the rollback actually serving?)"
fix: Roll back to the previous build (kubectl rollout undo, or the remediator's tier-2 proposal after a human approves); then fix forward through the pipeline.
tier: 2
learned_from: [INC-0006, INC-0010, INC-0014]
---
Notes: The rate-window trap (INC-0010): a 2-5 minute window can fire AFTER the pipeline's
own rollback for errors the bad build already produced — the AI ranked the rollback as
the cause once; it is never the cause. Since Day 6 the pipeline's Verify stage rolls back
on its own within ~2.5 min of a bad deploy; a human sees the alert after the fix in the
common case. Look-alike: kb-001 (same alerts, no deploy, fraud_service_timeout).
