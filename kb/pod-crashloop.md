---
id: kb-006
title: A pod crash-loops
services: [activation, egift, incident-bot, remediator, crashtest]
symptoms:
  - CrashLoopBackOff in kubectl get pods; kube_pod_container_status_restarts_total climbing every 1-5 minutes
  - a <Service>Down or PodCrashLooping alert; for the lab's fixture, CrashtestCrashLooping
  - the container's previous log (kubectl logs --previous) ends with the reason: an exception, exit 1, OOMKilled in describe
  - readiness never true, so the Service has no endpoint: callers see connection refused / 503
discriminating_checks:
  - "kubectl -n payments get pods | grep -v Running; kubectl -n payments describe pod <name> | grep -A3 'Last State'   (exit code + reason: 137 = OOMKilled, 1 = the app, 2 = a self-check)"
  - "kubectl -n payments logs <pod> --previous --tail=30   (the crash's own words; empty = look at the Last State reason)"
  - "recent_deploys <service>: a deploy just before the loop = kb-002 (bad release), roll back; no deploy = config/secret/dependency"
  - "kubectl -n payments get events --sort-by=.lastTimestamp | tail   (FailedMount, BackOff, Unhealthy tell you which)"
fix: If a bad image, roll back (kb-002). If the app crashes on a bad config/secret, fix the input and restart. The remediator's tier-1 action deletes the pod once (a fresh start clears a transient); a loop that survives one restart is not transient and needs a human.
tier: 1
learned_from: [INC-0012]
---
Notes: The tier-1 drill (INC-0012) used a fixture pod that exits on purpose; the remediator's
restart cleared nothing (as designed) and the ticket said so. A crashloop with 100+ restarts
over days (Day 14's otel collector, exit 2, no log) is a different beast: capture the exit
first (terminationMessagePolicy: FallbackToLogsOnError). Liveness probes with a 1s timeout
under load produce a slow crashloop that looks like this (Day 13's Fluent Bit): check the
probe before the app.
