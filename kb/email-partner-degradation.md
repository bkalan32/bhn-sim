---
id: kb-003
title: Email partner degradation — eGift orders fail at send_email
services: [egift]
symptoms:
  - EgiftHighErrorRate firing (error rate 20-40%, not 100%)
  - egift_step_latency_seconds_bucket{step="send_email"} rises; generate_code and activate steps unchanged
  - EgiftStepSlow may fire for step=send_email
  - activation is HEALTHY (no activation alerts, activation error rate at baseline)
  - app.reason for egift errors names the email step / partner (not upstream_status=503 from activation)
discriminating_checks:
  - "Prometheus: histogram_quantile(0.95, sum(rate(egift_step_latency_seconds_bucket[5m])) by (le, step))   (only send_email moved = this pattern; activate moved = kb-001 via activation)"
  - "Prometheus: 100 * sum(rate(activation_requests_total{status=\"error\"}[5m])) / sum(rate(activation_requests_total[5m]))   (activation at baseline rules out the cascade)"
  - "Splunk: app.service=egift app.status=error | stats count by app.reason"
  - "kubectl -n payments get deploy egift -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -o 'EMAIL_FAIL_RATE[^}]*'   (the lab's knob; in a company: the provider's status page + who changed the Deployment outside the pipeline)"
fix: The partner has to recover; a retry queue for send_email limits customer impact. Lab: EMAIL_FAIL_RATE back to the README baseline (0.01). No safe automated action.
tier: 3
learned_from: [INC-0003, INC-0016]
---
Notes: The signature is a PARTIAL failure of one step in one service while the upstream
(activation) is fine — the opposite shape of kb-001's cascade. INC-0016 was found in a
game day 4 min after injection by the alert; the env change was outside the pipeline, so
the deploys collector saw nothing (a finding: the enrichment is blind to changes that do
not go through Jenkins).
