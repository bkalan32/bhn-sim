# Daily ops report — 2026-09-12

_generated 2026-09-12T17:02:36Z · claude-sonnet-4-5-20250929 · 174 words (cap 250) · 15234 ms · numbers not traceable to the data: none_

**DAILY OPERATIONS REPORT – 2026-09-12 17:02Z**

**1. HEADLINE**
One incident open (platform pod restarting); error budgets deeply exhausted; otherwise quiet overnight.

**2. LAST 24H**
10 incidents, all resolved except one:
- INC-1789152659-e2cb (egift, 2.0 min, tier 3 / none recorded)
- INC-1789152663-7a36 (activation, 2.0 min, tier 3 / none recorded)
- INC-1789152992-ee6d (egift, 6.1 min, tier 3 / none recorded)
- INC-1789153026-7443 (activation, 4.0 min, tier 3 / none recorded)
- INC-1789153324-9abd (activation, 2.0 min, tier 3 / none recorded)
- INC-1789156427-065f (incident-bot, 0.8 min, tier 3 / none recorded)
- INC-1789157005-c234 (egift, 6.0 min, tier 3 / none recorded)
- INC-1789157010-9d18 (activation, 8.0 min, tier 3 / none recorded)
- INC-1789230178-abbe (smoke-test, 2.0 min, tier 3 / none recorded)
- INC-1789231840-517b (platform, open, tier3/human pending)

One deploy: incident-bot build 38 at 2026-09-12T16:36:52Z.

Traffic: activation 6.9 req/s, 1.8% errors, 0.2s p95; egift 2.2 orders/s, 2.5% errors. Settlement last success 2.3 min ago, 5925 records, 0 failed jobs, 2309508 records in 24h. Health scores: platform 85.4, activation 85.1, egift 71.1, settlement 100.0 (no 24h deltas

## Data the model was given

```json
{
 "generated_at": "2026-09-12T17:02:36Z",
 "window": "last 24h unless stated",
 "health_scores": {
  "platform": {
   "now": 85.4,
   "24h_ago": null,
   "delta": null
  },
  "activation": {
   "now": 85.1,
   "24h_ago": null,
   "delta": null
  },
  "egift": {
   "now": 71.1,
   "24h_ago": null,
   "delta": null
  },
  "settlement": {
   "now": 100.0,
   "24h_ago": null,
   "delta": null
  }
 },
 "error_budgets": {
  "availability_30d_pct": -742.7,
  "latency_30d_pct": -109.7,
  "burn_rate_1h_now": 3.6
 },
 "traffic_now_vs_24h_ago": {
  "activation_req_per_s": 6.9,
  "activation_error_pct_now": 1.8,
  "activation_error_pct_24h_ago": null,
  "activation_p95_s_now": 0.2,
  "egift_orders_per_s": 2.2,
  "egift_error_pct_now": 2.5
 },
 "settlement": {
  "last_success_minutes_ago": 2.3,
  "last_run_records": 5925.0,
  "failed_jobs_24h": 0.0,
  "records_24h_sum_of_runs": 2309508.0
 },
 "incidents_24h": [
  {
   "id": "INC-1789152659-e2cb",
   "service": "egift",
   "status": "resolved",
   "opened": "2026-09-11T18:50:59Z",
   "duration_min": 2.0,
   "alerts": [
    "EgiftHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789152663-7a36",
   "service": "activation",
   "status": "resolved",
   "opened": "2026-09-11T18:51:03Z",
   "duration_min": 2.0,
   "alerts": [
    "ActivationHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789152992-ee6d",
   "service": "egift",
   "status": "resolved",
   "opened": "2026-09-11T18:56:32Z",
   "duration_min": 6.1,
   "alerts": [
    "EgiftHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": [
    "**The activation service is failing**, causing cascading failures into egift. Evidence: 373 of 377 total errors (98.9%) are activation-related (activation_failed, activation_unreachable, activation_timeout). The egift service calls activation during its \"activate\" step, so activation failures propagate directly into egift order failures. The alert runbook explicitly identifies this pattern as \"INC-0001's shape\" and directs responders to check activation first."
   ]
  },
  {
   "id": "INC-1789153026-7443",
   "service": "activation",
   "status": "resolved",
   "opened": "2026-09-11T18:57:06Z",
   "duration_min": 4.0,
   "alerts": [
    "ActivationHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789153324-9abd",
   "service": "activation",
   "status": "resolved",
   "opened": "2026-09-11T19:02:04Z",
   "duration_min": 2.0,
   "alerts": [
    "ActivationErrorBudgetBurnFast"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": [
    "**The fraud check dependency is timing out**, causing the vast majority of activation failures. Evidence: fraud_service_timeout accounts for 981 of ~1013 total errors (97%), and the fraud check is an outbound dependency inside the activation service. With no recent deploys, this points to a problem with the external fraud service endpoint or network path to it, not the activation code itself."
   ]
  },
  {
   "id": "INC-1789156427-065f",
   "service": "incident-bot",
   "status": "resolved",
   "opened": "2026-09-11T19:53:47Z",
   "duration_min": 0.8,
   "alerts": [
    "IncidentBotDown",
    "PaymentsPodCrashLooping"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": [
    "**Pod-level failure causing repeated crashes**, not deployment-related. The evidence: two sequential pods (tw479, then th5sw) both entered crash loops within minutes of each other, with no recent deploy. The first pod's crash loop resolved (likely deleted by the remediator as described in the alert), but its replacement (th5sw) is now also crash-looping. This pattern suggests an environmental issue (resource exhaustion, configuration problem, or external dependency failure) rather than bad code, since no new version was deployed."
   ]
  },
  {
   "id": "INC-1789157005-c234",
   "service": "egift",
   "status": "resolved",
   "opened": "2026-09-11T20:03:25Z",
   "duration_min": 6.0,
   "alerts": [
    "EgiftHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": [
    "**Activation service dependency failure** (kb-001 pattern). Evidence: (1) the dominant error reason is `activation_failed` (263 vs 4), meaning egift is failing at its \"activate\" step when it calls activation; (2) p95 activate step latency is 0.47s, consistent with a fail-fast timeout on the upstream call; (3) no egift deploy in 6h rules out a bad release of egift itself; (4) the alert runbook says \"If reason is activation_*, it is INC-0001's shape: look at activation first.\" The failure is upstream in activation, cascading into egift orders."
   ]
  },
  {
   "id": "INC-1789157010-9d18",
   "service": "activation",
   "status": "resolved",
   "opened": "2026-09-11T20:03:30Z",
   "duration_min": 8.0,
   "alerts": [
    "ActivationErrorBudgetBurnFast",
    "ActivationHighErrorRate"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": [
    "**Fraud dependency outage or timeout.** The evidence: fraud_service_timeout is the overwhelming reason (611 vs 57 issuer_declined), p95 latency is capped at 0.48s (consistent with the fail-fast timeout signature, not the 3s backend wait), error rate climbed to 100% then fell to ~45% by the snapshot, and no activation deploy occurred in the last 30 minutes. This matches **kb-001** exactly \u2014 the most-rehearsed pattern in the repository."
   ]
  },
  {
   "id": "INC-1789230178-abbe",
   "service": "smoke-test",
   "status": "resolved",
   "opened": "2026-09-12T16:22:58Z",
   "duration_min": 2.0,
   "alerts": [
    "RoutingProbe"
   ],
   "remediation": [
    "tier 3 / none recorded"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789231840-517b",
   "service": "platform",
   "status": "open",
   "opened": "2026-09-12T16:50:40Z",
   "duration_min": null,
   "alerts": [
    "PlatformPodRestarting"
   ],
   "remediation": [
    "tier3/human"
   ],
   "hypothesis_cause": [
    "**The OpenTelemetry collector pod is crash-looping.** Evidence: 6 restarts in the last hour with no recent deploys. The collector runs in namespace `tracing` and receives traces from activation, egift, and settlement. Crash loops typically indicate a configuration error, resource exhaustion (OOM), or a bad connection to its backend (Tempo). The alert description notes this pattern was found 70 scheduler restarts and 112 collector restarts late in Day 14 \u2014 suggesting this is a known failure mode."
   ]
  }
 ],
 "open_incidents_now": [
  "INC-1789231840-517b"
 ],
 "remediation_pending_proposals": [],
 "write_ups_and_kb": [
  {
   "incident": "INC-1789231840-517b",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789230178-abbe",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789157010-9d18",
   "write_up": "INC-0019-diagnosis",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789157005-c234",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789156427-065f",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789153324-9abd",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789153026-7443",
   "write_up": "INC-0009-diagnosis",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789152992-ee6d",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789152663-7a36",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789152659-e2cb",
   "write_up": "none",
   "kb_cites_it": false
  }
 ],
 "deploys_24h": {
  "incident-bot": [
   {
    "kind": "deploy",
    "text": "build 38: Day 18: startupProbe, /reports, per-service counter",
    "at": "2026-09-12T16:36:52Z"
   }
  ]
 },
 "alerts_firing_now": [
  {
   "alert": "KubeJobFailed",
   "severity": "warning",
   "service": "kps-kube-state-metrics"
  },
  {
   "alert": "KubeJobFailed",
   "severity": "warning",
   "service": "kps-kube-state-metrics"
  },
  {
   "alert": "KubeJobFailed",
   "severity": "warning",
   "service": "kps-kube-state-metrics"
  },
  {
   "alert": "PlatformPodRestarting",
   "severity": "warning",
   "service": "platform"
  },
  {
   "alert": "PlatformPodRestarting",
   "severity": "warning",
   "service": "platform"
  }
 ],
 "platform_restarts": {
  "restarts_24h": 63.3848,
  "pods_restarting_1h": {
   "tempo-0": 2.0235,
   "prometheus-kps-kube-prometheus-stack-prometheus-0": 1.0118,
   "kube-controller-manager-bhn-sim-control-plane": 2.0235,
   "otel-opentelemetry-collector-86b6bfc65-6vsl4": 6.0705,
   "newrelic-nrk8s-ksm-6688f4bbd9-fsxgc": 2.0235,
   "kps-kube-prometheus-stack-operator-5bd7cfb8db-tncl4": 3.0353,
   "kube-scheduler-bhn-sim-control-plane": 2.0235,
   "kps-kube-state-metrics-788bdc5f97-r9fpr": 2.0235,
   "kps-prometheus-node-exporter-kcffj": 2.0235,
   "fluent-bit-kmfjb": 2.0193
  }
 },
 "drift": "no data (not checked this run; the Jenkins job plans first, or use --plan)",
 "kpis_7d": {
  "window_days": 7,
  "generated_at": "2026-09-12T17:02:36Z",
  "mttd_s": {
   "window": 183.4,
   "all_time": 183.4,
   "n_window": 5,
   "n_all": 5,
   "definition": "first alert - fault injected (drill notes on the record); non-drill incidents have no fault time"
  },
  "mttr_min": {
   "window": 6.9,
   "all_time": 6.8,
   "n_window": 43,
   "n_all": 45,
   "definition": "resolved - opened (duration_min on the record); includes the alerts' resolve windows"
  },
  "incidents_by_service": {
   "window": {
    "platform": 1,
    "smoke-test": 1,
    "activation": 14,
    "egift": 14,
    "incident-bot": 2,
    "settlement": 8,
    "crashtest": 4
   },
   "total": 44,
   "promql": "sum by (service) (increase(incidents_created_total[7d]))"
  },
  "remediation_share_pct": {
   "window": 0.0,
   "history_entries": 1,
   "remediated_incidents": [],
   "declined": [],
   "promql": "sum(increase(remediation_actions_total{mode=~\"auto|approved\",result=\"ok\"}[7d])) / sum(increase(incidents_created_total[7d]))"
  },
  "error_budget_remaining_pct": {
   "availability_30d": -742.7,
   "latency_30d": -109.7
  },
  "alert_precision_pct": {
   "window": 46.7,
   "fired": [
    "ActivationErrorBudgetBurnFast",
    "ActivationErrorBudgetBurnSlow",
    "ActivationHighErrorRate",
    "ActivationHighLatency",
    "AlertmanagerClusterCrashlooping",
    "AlertmanagerClusterFailedToSendAlerts",
    "AlertmanagerFailedToSendAlerts",
    "EgiftHighErrorRate",
    "EgiftHighLatency",
    "EgiftStepSlow",
    "IncidentBotDown",
    "InfoInhibitor",
    "KubeAPIErrorBudgetBurn",
    "KubeControllerManagerInstanceUnreachable",
    "KubeDaemonSetRolloutStuck",
    "KubeJobFailed",
    "KubePodCrashLooping",
    "KubePodNotReady",
    "KubeProxyInstanceUnreachable",
    "KubeSchedulerInstanceUnreachable",
    "NodeSystemSaturation",
    "PaymentsPodCrashLooping",
    "PlatformPodRestarting",
    "RemediatorDown",
    "SettlementJobFailed",
    "SettlementStale",
    "SettlementZeroRecords",
    "TargetDown",
    "etcdInsufficientMembers",
    "etcdMembersDown"
   ],
   "ticketed": [
    "ActivationErrorBudgetBurnFast",
    "ActivationErrorBudgetBurnSlow",
    "ActivationHighErrorRate",
    "ActivationHighLatency",
    "EgiftHighErrorRate",
    "EgiftHighLatency",
    "EgiftStepSlow",
    "IncidentBotDown",
    "PaymentsPodCrashLooping",
    "PlatformPodRestarting",
    "SettlementJobFailed",
    "SettlementStale",
    "SettlementZeroRecords",
    "TargetDown"
   ],
   "noise": [
    "AlertmanagerClusterCrashlooping",
    "AlertmanagerClusterFailedToSendAlerts",
    "AlertmanagerFailedToSendAlerts",
    "InfoInhibitor",
    "KubeAPIErrorBudgetBurn",
    "KubeControllerManagerInstanceUnreachable",
    "KubeDaemonSetRolloutStuck",
    "KubeJobFailed",
    "KubePodCrashLooping",
    "KubePodNotReady",
    "KubeProxyInstanceUnreachable",
    "KubeSchedulerInstanceUnreachable",
    "NodeSystemSaturation",
    "RemediatorDown",
    "etcdInsufficientMembers",
    "etcdMembersDown"
   ],
   "definition": "alert names that reached a ticket / alert names that fired (Watchdog excluded); coarse by design \u2014 a name is the unit the audit judges"
  },
  "deploys": {
   "note": "no data (set JENKINS_USER/JENKINS_PASS)",
   "source": "Jenkins deploy-service builds"
  }
 }
}
```
