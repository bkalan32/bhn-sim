---
id: kb-004
title: Settlement job crashes — exit non-zero, db_unreachable
services: [settlement]
symptoms:
  - SettlementJobFailed firing (a Job with a failed pod in the last 15 min)
  - the job pod is in Error state; kubectl logs shows reason=db_unreachable (or a traceback) and exit 1
  - settlement_last_run_status = 0; settlement_last_success_timestamp not advancing (SettlementStale after the window)
  - settlement_records_processed did NOT push a new value (a crash pushes nothing; compare kb-005 which pushes 0)
discriminating_checks:
  - "kubectl -n payments get jobs --sort-by=.metadata.creationTimestamp | tail -3; kubectl -n payments logs job/<newest> | tail -5   (the reason is on the last line)"
  - "Prometheus: settlement_last_run_status, settlement_records_processed, time() - settlement_last_success_timestamp"
  - "kubectl -n payments get cronjob settlement -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env}'   (SETTLEMENT_FAIL_MODE=crash is the lab's knob)"
fix: Re-run the job (kubectl create job --from=cronjob/settlement) once the cause is cleared — the remediator does this automatically (tier 1, one retry after 180s); if the retry also fails, the cause is upstream (the database) and a human owns it.
tier: 1
learned_from: [INC-0013]
---
Notes: A crash is the LOUD settlement failure and the easy one; kb-005 is the quiet one.
Concurrency policy Forbid (Day 5) means a hung job cannot overlap the next tick — check
activeDeadlineSeconds if a job shows Running for more than 4 minutes.
