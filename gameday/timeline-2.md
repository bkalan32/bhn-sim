
## Run 2 — started 2026-09-12T20:33:06Z (T0), on EKS

- `20:38:51Z` 20:36Z paged: ActivationLatencyBudgetBurn warning, ticket INC-1789245416-72a4, remediator tier3->human (no signature). p95 0.96s, burn 1h 17.2x, no errors
- `20:40:55Z` 20:40Z hypothesis: 'slow issuer', medium, rejects kb-001/kb-002 on evidence. Disagree with the lead: issuer_declined 3% is baseline noise, not a signal. Deploys collector says no change in 6h — checking the deployment itself
- `20:47:36Z` 20:44Z copilot: config change ~20:33Z, BASE_LATENCY_MS=600 on deploy/activation, no image change, no dependency implicated (FRAUD_SVC_DOWN=false, logs only issuer_declined via CloudWatch). Deploys collector missed it (annotations only). Limit: what+when known, who+why not recorded. Decision: revert the unpipelined change
- `20:50:19Z` 20:49Z settlement: cron 20:44 failed, remediator tier-1 re-run failed 20:44:02, retry failed 20:47:19, now in cooldown (policy: retry 1, cooldown 600s). Two failures seen -> acting as the vendor: resetting the mode. Egift ticket ce45 open since 20:45 (tier3 human) — next
- `20:52:11Z` 20:53Z egift: hypothesis high confidence kb-003, partner email degradation, 82 email_delivery_failed vs 7 (CloudWatch). Escalating to the partner; remediator correctly tier3. Not a platform fix
- `20:53:32Z` 20:53Z settlement: 20:50 cron job created 19s before the reset, failed as expected; SettlementStale now firing too; remediator in cooldown until ~20:57. Waiting for the 20:55 tick — no action
- `20:59:34Z` 20:59Z settlement healthy (20:55 run Complete, Stale/ZeroRecords cleared). Only SettlementJobFailed left, one instance per failed job; rule has a 900s start-time window so the last (20:50 job) drops at 21:05. Not deleting jobs, not resolving by hand — the platform closes it
- `21:06:58Z` 21:06Z settlement resolved by the platform (24 min). All three closed; human actions on the platform: revert activation config, vendor reset, partner reset. No manual resolves
- `21:08:03Z` 20:53Z egift: partner 'recovered' (EMAIL_FAIL_RATE reset to 0.01) after the escalation note; remediator never touched it (tier3)
- `21:08:03Z` 20:52:56Z activation 72a4 resolved by the platform (16 min, 5 min after the revert); 20:55:11Z egift ce45 resolved by the platform (10 min, 2 min after the partner reset)
