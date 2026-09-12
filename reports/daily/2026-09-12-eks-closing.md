# Daily ops report — 2026-09-12-eks-closing

_generated 2026-09-12T21:08:20Z · claude-sonnet-4-5-20250929 · 170 words (cap 250) · 15065 ms · numbers not traceable to the data: none · complete (4 sections)_

1. HEADLINE
Platform stable; all incidents resolved, error budgets exhausted, 3 KubeJobFailed alerts still firing.

2. LAST 24H
Incidents (all resolved):
- INC-1789245706-ac0f, settlement, 24 min, tier3/human; matched kb-005 (zero-records silent failure), auto-remediation attempted and failed twice before human intervention.
- INC-1789245416-72a4, activation, 16 min, tier3/human; ActivationLatencyBudgetBurn alert.
- INC-1789245911-ce45, egift, 10 min, tier3/human; matched kb-003 (email partner degradation), error rate 3.4%.
- INC-1789244628-64d9, smoke-test, 2 min, tier3/human; RoutingProbe alert.

Deploys: none in 24h.

Metrics: activation 4.3 req/s, 2.0% errors, 0.2s p95; egift 1.6 orders/s, 3.4% errors; settlement last success 3.4 min ago, 5735 records last run, 292702 records in 24h, 3 failed jobs in 24h. Platform health 82.6, activation 87.0, egift 60.8, settlement 100.0 (no 24h deltas available). Error budgets: availability -300.6%, latency -1732.1%, 1h burn rate 4.0.

3. RISKS
Error budgets exhausted (availability -300.6%, latency -1732.1%). Three KubeJobFailed alerts firing now on kps-kube-state-metrics. Drift: no data. All collectors up.

4. NEEDS A HUMAN
Four incidents lack write-ups: INC-1789245911-ce45, INC-1789245706-ac0f, INC-1789245416-72a4, INC-1789244628-64d9. No KB entries created. No pending remediations.

## Data the model was given

```json
{
 "generated_at": "2026-09-12T21:08:20Z",
 "window": "last 24h unless stated",
 "health_scores": {
  "platform": {
   "now": 82.6,
   "24h_ago": null,
   "delta": null
  },
  "activation": {
   "now": 87.0,
   "24h_ago": null,
   "delta": null
  },
  "egift": {
   "now": 60.8,
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
  "availability_30d_pct": -300.6,
  "latency_30d_pct": -1732.1,
  "burn_rate_1h_now": 4.0
 },
 "traffic_now_vs_24h_ago": {
  "activation_req_per_s": 4.3,
  "activation_error_pct_now": 2.0,
  "activation_error_pct_24h_ago": null,
  "activation_p95_s_now": 0.2,
  "egift_orders_per_s": 1.6,
  "egift_error_pct_now": 3.4
 },
 "settlement": {
  "last_success_minutes_ago": 3.4,
  "last_run_records": 5735,
  "failed_jobs_24h": 3,
  "records_24h_sum_of_runs": 292702
 },
 "incidents_24h": [
  {
   "id": "INC-1789244628-64d9",
   "service": "smoke-test",
   "status": "resolved",
   "opened": "2026-09-12T20:23:48Z",
   "duration_min": 2.0,
   "alerts": [
    "RoutingProbe"
   ],
   "remediation": [
    "tier3/human"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789245416-72a4",
   "service": "activation",
   "status": "resolved",
   "opened": "2026-09-12T20:36:56Z",
   "duration_min": 16.0,
   "alerts": [
    "ActivationLatencyBudgetBurn"
   ],
   "remediation": [
    "tier3/human"
   ],
   "hypothesis_cause": null
  },
  {
   "id": "INC-1789245706-ac0f",
   "service": "settlement",
   "status": "resolved",
   "opened": "2026-09-12T20:41:46Z",
   "duration_min": 24.0,
   "alerts": [
    "SettlementJobFailed",
    "SettlementStale",
    "SettlementZeroRecords"
   ],
   "remediation": [
    "cooldown/skipped (settlement-crash)",
    "auto/ok (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "auto/fail (settlement-crash)",
    "cooldown/skipped (settlement-crash)",
    "auto/fail (settlement-crash)",
    "tier3/human"
   ],
   "hypothesis_cause": [
    "**Matches kb-005** (seen in INC-0005, INC-0017): Settlement job ran but reconciled nothing \u2014 a silent failure producing zero records. Evidence: SettlementZeroRecords firing with `settlement_records_processed` pushed as 0, `settlement_last_run_status` = 0.0 (the job refused to call it success since Day 8), and `minutes_since_success` = 6.55 (timestamp not advancing). The kb-005 pattern predicts SettlementJobFailed will join ~2 min after SettlementZeroRecords; the incident opened 15 seconds after the first alert, so that second signal may still be arriving. No deploy rules out a code change; the job itself is failing for an input/config reason."
   ]
  },
  {
   "id": "INC-1789245911-ce45",
   "service": "egift",
   "status": "resolved",
   "opened": "2026-09-12T20:45:11Z",
   "duration_min": 10.0,
   "alerts": [
    "EgiftHighErrorRate"
   ],
   "remediation": [
    "tier3/human"
   ],
   "hypothesis_cause": [
    "**Email partner degradation** \u2014 matches **kb-003**. Evidence: (1) email_delivery_failed dominates the reason histogram (82 vs 7 activation_failed), (2) the error rate is partial (34.95% over 5m, 62.4% over 2m \u2014 elevated but not 100%), (3) p95 activate step latency is 0.98s (normal, not the 0.3-0.5s timeout cap of kb-001's fraud outage), (4) activation_failed count is low (7) \u2014 if activation were down we would see hundreds of upstream_status=503 errors as in kb-001's cascade, and (5) no recent deploy. The signature matches kb-003's email partner degradation: one step of one service failing while the upstream (activation) remains healthy."
   ]
  }
 ],
 "open_incidents_now": [],
 "remediation_pending_proposals": [],
 "write_ups_and_kb": [
  {
   "incident": "INC-1789245911-ce45",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789245706-ac0f",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789245416-72a4",
   "write_up": "none",
   "kb_cites_it": false
  },
  {
   "incident": "INC-1789244628-64d9",
   "write_up": "none",
   "kb_cites_it": false
  }
 ],
 "deploys_24h": {
  "note": "no deploys or rollbacks in 24h"
 },
 "collectors_now": {
  "metrics": "ok",
  "deploys": "ok",
  "logs": "ok"
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
  }
 ],
 "platform_restarts": {
  "restarts_24h": 0,
  "pods_restarting_1h": {}
 },
 "drift": "no data (not checked this run; the Jenkins job plans first, or use --plan)",
 "kpis_7d": {
  "window_days": 7,
  "generated_at": "2026-09-12T21:08:20Z",
  "mttd_s": {
   "window": null,
   "all_time": null,
   "n_window": 0,
   "n_all": 0,
   "definition": "first alert - fault injected (drill notes on the record); non-drill incidents have no fault time"
  },
  "mttr_min": {
   "window": 13.0,
   "all_time": 13.0,
   "n_window": 4,
   "n_all": 4,
   "definition": "resolved - opened (duration_min on the record); includes the alerts' resolve windows"
  },
  "incidents_by_service": {
   "window": {
    "egift": 1,
    "settlement": 1,
    "activation": 1,
    "smoke-test": 1
   },
   "total": 4,
   "promql": "sum by (service) (increase(incidents_created_total[7d]))"
  },
  "remediation_share_pct": {
   "window": 25.0,
   "history_entries": 14,
   "remediated_incidents": [
    "INC-1789245706-ac0f"
   ],
   "declined": [],
   "promql": "sum(increase(remediation_actions_total{mode=~\"auto|approved\",result=\"ok\"}[7d])) / sum(increase(incidents_created_total[7d]))"
  },
  "error_budget_remaining_pct": {
   "availability_30d": -299.0,
   "latency_30d": -1741.6
  },
  "alert_precision_pct": {
   "window": 71.4,
   "fired": [
    "ActivationLatencyBudgetBurn",
    "EgiftHighErrorRate",
    "InfoInhibitor",
    "KubeJobFailed",
    "SettlementJobFailed",
    "SettlementStale",
    "SettlementZeroRecords"
   ],
   "ticketed": [
    "ActivationLatencyBudgetBurn",
    "EgiftHighErrorRate",
    "SettlementJobFailed",
    "SettlementStale",
    "SettlementZeroRecords"
   ],
   "noise": [
    "InfoInhibitor",
    "KubeJobFailed"
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
