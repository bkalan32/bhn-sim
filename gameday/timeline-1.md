# Game day 1 — timeline (the scribe's file)

`./gameday/note.sh "…"` appends here with a UTC timestamp. Rules: what you see, what you do,
when. Not what you think — hypotheses go in too, but labelled ("hypothesis: …") so the retro
can tell observation from guess.


## Run 1 — started 2026-09-09T14:44:17Z (T0)

- `14:49:05Z` back from the 5-min walk; opened Grafana Platform Overview first
- `14:49:05Z` SEE platform health 69 and falling; active critical alerts 0, active warnings 0; deploys/rollbacks 24h: none
- `14:49:06Z` SEE activation: health 78, 6.7 req/s, error rate 2.3%, p95 173 ms — looks normal; error budget -789% is the pre-existing drill debt
- `14:49:06Z` SEE egift: health 30 RED, 1.8 req/s (traffic normal), error rate 35.4% RED, p95 order latency 267 ms, p95 activate step 186 ms — latency fine, errors not
- `14:49:07Z` SEE settlement: health 100, 1.6 min since last success, 4K records last run, mismatches 2, last run status 1 — normal
- `14:49:08Z` SEE remediation row (24h): auto 3, awaiting 0, approved 0, failed/skipped 3, human required 4 — all from yesterday? need timestamps
- `14:49:08Z` OBSERVATION egift errors 35% but 0 active alerts on the overview — either the alert's for: window has not elapsed or the panel lags
- `14:49:10Z` hypothesis: egift is the sick row; activation looks healthy underneath it (activate step green) — do NOT assume, check the ticket/context next
- `14:49:10Z` NEXT python3 tools/inc.py list open
- `14:50:54Z` SEE overview ~1 min later: platform health 65 (falling); ACTIVE CRITICAL ALERTS 1 (was 0), warnings 0; still no deploys/rollbacks 24h
- `14:50:54Z` SEE egift: health 24, error rate 42.3% (was 35.4%, rising), order rate 1.5/s, p95 order latency 681 ms (was 267), activate step 550 ms (was 186) — latency now ORANGE too
- `14:50:54Z` SEE activation: health 71 (was 78), 5.3 req/s (was 6.7), error rate 3.2% (was 2.3), p95 484 ms (was 173) — latency up on activation as well
- `14:50:54Z` SEE settlement: health 100, 2.6 min since success, 4K records, status 1 — unchanged
- `14:50:54Z` SEE ticket layer: open incidents 0, incidents 24h 18, webhooks (1h) 0, bot UP — the critical alert has not become a ticket yet (group_wait?) — recheck in 30 s
- `14:50:54Z` OBSERVATION latency rose on BOTH services in the same minute; the error spike is egift-only. Two different symptoms — keep them separate until the ticket/context says otherwise
- `14:50:54Z` NEXT wait for the ticket: python3 tools/inc.py list open, then timeline/context/hypothesis on it
- `14:51:14Z` SEE remediation row: auto 3 / awaiting 0 / approved 0 / failed-skipped 3 / human 4 — unchanged from yesterday; BUT 'Remediator scraped' went 1 -> 0 (RED): Prometheus is not scraping the remediator right now
- `14:51:14Z` NEXT is the remediator up? kubectl get pods + rem.py health — if it is down, nothing automated will act on anything from here
- `14:53:21Z` SEE remediator pod Running, health ok v28 dry_run=false — the scrape 0 was transient; automation is available
- `14:53:21Z` SEE ticket: INC-1788965364-b5c7 egift critical EgiftHighErrorRate opened 14:49:24Z — one open incident
- `14:53:21Z` SEE egift pods are 5m37s and 7m01s old — REPLACED minutes ago; every other pod is hours old. Something changed egift's Deployment ~7 min ago, and the overview shows no deploy annotation
- `14:53:21Z` SEE settlement-29816090-26nm8 Error 30 s ago and a second pod for the same job Running 3 s — the latest settlement run FAILED and is retrying; the three before it Completed
- `14:53:21Z` NEXT read the egift ticket (timeline/context/hypothesis); then what changed egift (rollout history); then the settlement Error pod's log — separately
- `14:54:19Z` READ ticket b5c7: first alert 14:48:35Z, ticket 14:49:24Z (49 s), context 14:49:33Z, hypothesis 14:50:38Z; remediator 14:50:39Z: no signature -> tier 3 human required
- `14:54:19Z` READ context: error 24%, p95 0.99 s, activate step 0.63 s; deploys: NONE in 6h; log reasons: email_delivery_failed 107, activation_failed 32
- `14:54:19Z` READ hypothesis: most likely EMAIL DELIVERY failure (77% of errors), no deploy; alternative: activation cascade (32 activation_failed); confidence medium
- `14:54:19Z` FINDING the hypothesis's 'next checks' 1 and 2 are invented commands (kubectl exec deploy/kps-prometheus -- promql does not exist) — do not run them; retro: misleading tooling
- `14:54:19Z` FINDING the AI OPEN draft failed (ok=false, 48.6 s) — the hypothesis draft succeeded; retro: why did one call fail?
- `14:54:19Z` SEE egift rollout history: revisions 6,7,8, all CHANGE-CAUSE <none>; revision 8 is the 7-min-old pods — a rollout with no recorded cause and no pipeline annotation = a change outside the pipeline
- `14:54:19Z` READ settlement-29816090 log: 'settlement starting fail_mode=silent strict=True' then 'refusing to report success: zero records reconciled' — the job's own self-check failed it. fail_mode=silent is NOT the baseline (none)
- `14:54:19Z` DECISION two independent problems: (1) egift email step failing, no deploy, remediator correctly declined; (2) settlement running in fail_mode=silent. Treat as two incidents
- `14:55:40Z` READ egift revision 8 env: EMAIL_FAIL_RATE=0.35 — README incident-controls table says baseline 0.01. Revision 8 = the 7-min-old rollout, no change-cause, no pipeline annotation: a config change made by hand
- `14:55:40Z` READ copilot (6 tools, 14.6 s): activation error 1.66%, p95 0.18 s, no activation alerts — activation NOT affected (right, cited). But it concluded 'not isolated to send_email, errors elsewhere' from send_email LATENCY being normal (92 ms) — it answered an error question with a latency metric and never looked at error reasons or step error counts. Conclusion wrong; retro Eval 6c
- `14:55:40Z` SEE second ticket INC-1788965584-fca7 settlement critical SettlementZeroRecords 14:53:04Z; remediator: tier 3 human required (its signature is on SettlementJobFailed, and this group opened with ZeroRecords)
- `14:55:40Z` READ rem.py actions: two tier-3 notes (b5c7 14:50:39, fca7 14:53:04) — automation looked at both and declined both; no proposals pending
- `14:55:40Z` DECISION fault 1 = egift EMAIL_FAIL_RATE 0.35 set by hand ~14:44; fault 2 = settlement CronJob SETTLEMENT_FAIL_MODE=silent (job log). Reverting both to baseline now; in a company: egift = provider ticket + who changed the Deployment; settlement = same question + finance told 0 records
- `14:55:51Z` FIX egift EMAIL_FAIL_RATE=0.01 (rollout, ~30 s); expect EgiftHighErrorRate to clear in 2-4 min (2m window + for)
- `14:55:51Z` FIX settlement SETTLEMENT_FAIL_MODE=none + a manual job from the CronJob so a SUCCESS lands now instead of at the next tick
- `14:58:21Z` SEE jobs: settlement-29816095 Failed (cron tick 14:55), settlement-remediator-1788965704 Failed (the remediator's re-run, created 14:55:04 — 47 s BEFORE my fix), settlement-manual-1788965751 Complete 17 s (my job, after the fix)
- `14:58:21Z` READ settlement ticket fca7: opened on ZeroRecords 14:53:04 -> tier 3 (no signature for that alert); JobFailed joined the group 14:55:04 -> AUTO rerun_settlement 14:55:57 FAILED with the job's own reason (zero records, mode still silent) -> 'retry once in 180 s' -> 14:57:04 COOLDOWN skipped. Automation did exactly what the policy says, and its FAILED note quoted the cause
- `14:58:21Z` SEE status 14:57:34: egift err 14.9% and falling (alert needs <10% over 2 min), health 30->; settlement last success 92 s ago (my manual job) — SettlementZeroRecords is no longer in Alertmanager's firing list; SettlementJobFailed x2 stays until 15 min after the failed jobs started (~15:10Z)
- `14:58:21Z` OBSERVATION the firing list also carries 9 kps-* alerts (etcd, scheduler, proxy TargetDown) — kind's permanent false positives, routed to null; noise on the status screen during an incident — retro: filter them
- `14:58:21Z` EXPECT remediator retry at ~14:58:57 if the ticket is still open — mode is none now, so it should SUCCEED; that will be automation finishing what a human fixed
- `15:02:35Z` SEE verify: 0 of 2 faults live; egift b5c7 RESOLVED (9.6 min, resolution draft attached); settlement fca7 still open — three SettlementJobFailed (cron 14:55, remediator 14:55, cron 15:00?) inside their 15-min window
- `15:02:35Z` READ fca7 14:59:14: remediator AUTO retry 1/1 rerun_settlement SUCCEEDED — job settlement-remediator-1788965937 Complete, records=4517. I fixed the cause at 14:55:51; the platform's own retry produced the first clean run after it
- `15:02:35Z` WAITING settlement ticket resolves when the last failed job is 15 min old (~15:10-15:15Z) — the alert's clock, not the fix's
