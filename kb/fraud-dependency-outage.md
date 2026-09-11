---
id: kb-001
title: Fraud dependency outage or timeout
services: [activation, egift]
symptoms:
  - ActivationHighErrorRate firing, error rate climbing toward 100% (the ticket's metrics snapshot is a 5m rate and reads ~45% while the alert's 2m window says 100% — same outage, two windows, not a recovery)
  - ActivationErrorBudgetBurnFast follows (burn 14x-100x) — sometimes minutes AFTER the fix, from the long window; a second ticket for an incident that is over is that alert, not a relapse (Day 18)
  - reason=fraud_service_timeout dominates app.reason in the logs (hundreds vs tens of issuer_declined)
  - p95 latency rises to ~0.3-0.5s and STAYS there (the fail-fast timeout, Day 7), not to 3s
  - no deploy or rollback of activation in the last 30 minutes
  - egift orders fail at the activate step with upstream_status=503 (EgiftHighErrorRate may follow)
discriminating_checks:
  - "Splunk: index=main app.service=activation app.status=error earliest=-10m | stats count by app.reason   (fraud_service_timeout >> issuer_declined = this pattern; velocity_check_blocked = kb-002)"
  - "Prometheus: histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))   (~0.3-0.5s capped = dependency timeout; unchanged = kb-002)"
  - "recent_deploys activation / Grafana annotations: nothing in 30 min rules out a release"
  - "kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -o 'FRAUD_SVC_DOWN[^}]*'   (the lab's knob; in a company: the provider's status page)"
fix: Restore the fraud dependency — external, or in the lab FRAUD_SVC_DOWN=false. No safe automated action; escalate to the provider/on-call with the reason histogram attached.
tier: 3
learned_from: [INC-0001, INC-0007, INC-0008, INC-0009, INC-0011, INC-0018, INC-0019]
---
Notes: The most-rehearsed pattern in the repo (six times). The fail-fast client timeout
(Day 7, INC-0004) is why p95 caps at ~0.3-0.5s instead of stacking to 3s — that cap is now
part of the signature. On EKS (INC-0018) the pattern was identical without the log
histogram; the histogram was in CloudWatch. Look-alike: kb-002 (bad release) — same
alerts, different reason (velocity_check_blocked) and a deploy in the last 30 min.
