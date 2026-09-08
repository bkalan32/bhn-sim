# INC-0010 — Drill B: bad deploy, enriched (generated 2026-09-08T01:01:40Z)

Record: `INC-1788828923-e7d8`

## Timeline

```
  INC-1788828923-e7d8  resolved  service=activation  severity=critical
  first alert 2026-09-08T00:55:04Z   opened 2026-09-08T00:55:23Z   resolved 2026-09-08T01:01:28Z   duration 6.1 min
  2026-09-08T00:55:23Z  alerts_firing     ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:55:23Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "ok"}, "latency_ms": 360}
  2026-09-08T00:55:30Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 6657}
  2026-09-08T00:55:47Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 17191}
  2026-09-08T00:57:24Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:59:22Z  note              drill: bad deploy (velocity check) shipped via pipeline; auto-rollback is the safety net
  2026-09-08T01:01:28Z  alerts_resolved   ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T01:01:28Z  incident_resolved {"duration_min": 6.1}
  2026-09-08T01:01:40Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 11554}
```

## Context (enrichment)

```
  collected 2026-09-08T00:55:23Z  service=activation
  metrics      ok
    error_rate_pct           36.41
    p95_latency_s            0.17
    req_per_s                5.69
    health_score             40.0
    error_budget_burn_1h     26.44
  deploys      ok
    rollback      0.3 min before alert  2026-09-08T00:54:48Z  AUTO-ROLLBACK build 19: add velocity check for fraud team (Day 10 drill B)
    deploy        2.6 min before alert  2026-09-08T00:52:30Z  build 19: add velocity check for fraud team (Day 10 drill B)
  log reasons  ok
       600  velocity_check_blocked
        63  issuer_declined
```

## ai_hypothesis

```
## WHAT WE KNOW

- **ActivationErrorBudgetBurnFast** firing at 2026-09-08T00:55:04Z: 1h error rate is 14.4x the 0.5% budget, burning at 26x — whole month gone in ~2 days.
- Current error rate is 36.41%, request rate 5.69 req/s, p95 latency 0.17s, health score 40.0.
- Deploy of build 19 ("add velocity check for fraud team") occurred at 2026-09-08T00:52:30Z (2.6 minutes before first alert), followed by AUTO-ROLLBACK at 2026-09-08T00:54:48Z (0.3 minutes before first alert).
- Top error reason: `velocity_check_blocked` (600 occurrences), followed by `issuer_declined` (63 occurrences).
- No responder actions recorded yet.

## MOST LIKELY CAUSE

**The rollback itself introduced or failed to resolve the error spike.** The auto-rollback occurred only 0.3 minutes (18 seconds) before the first alert fired, meaning the alert triggered *after* the rollback completed. The dominant error reason `velocity_check_blocked` (600 vs 63 for the next error) suggests the velocity check feature is still active or the rollback left configuration/state behind. The original deploy was 2.6 minutes before the alert, but the rollback's timing makes it the proximate event.

## ALTERNATIVE

**The original build 19 deploy caused the issue and the rollback hasn't propagated yet.** If the rollback takes time to restart pods or clear caches, the velocity check code may still be running. Evidence that would confirm: checking pod restart times and verifying which build version is currently serving traffic would show whether the rollback completed successfully.

## SUGGESTED NEXT CHECKS

1. **Verify running build version:** `kubectl get pods -n activation -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u` — confirm whether build 19 or the prior version is actually running.
2. **Check error timeline in Splunk:** `index=main app.service=activation app.status=error earliest=-10m | timechart span=1m count by app.reason` — see when `velocity_check_blocked` errors started relative to deploy and rollback times.
3. **Inspect velocity check logic:** `kubectl logs -n activation -l app=activation --tail=100 | grep -i velocity` — look for configuration errors, missing dependencies, or logic bugs in the velocity check feature.

## CONFIDENCE

**Medium.** All context collectors succeeded. The timing is clear: rollback 18 seconds before alert, with a smoking-gun error reason (`velocity_check_blocked`) tied to the feature name. However, we lack confirmation of which build is actually running post-rollback and whether the velocity check is a code path or a configuration flag that persists across rollbacks.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

**ActivationErrorBudgetBurnFast** is firing for the activation service at critical severity. First alert at **2026-09-08T00:55:04Z**. Card activation is failing: error rate is 36.41% (measured), burning error budget at 26.44x—the whole month exhausted in ~2 days. Build 19 deployed at 00:52:30Z and auto-rolled back at 00:54:48Z (0.3 min before first alert); top error is `velocity_check_blocked` (600 occurrences). Runbook says: check Grafana 'Activation SLO' burn-rate panel, then Splunk: `index=main app.service=activation app.status=error | stats count by app.reason`.

---

## 2. STAKEHOLDER UPDATE

Customers attempting to activate payment cards are experiencing a high rate of failures starting at 00:55:04 UTC. A recent deployment was automatically rolled back, but no responder actions recorded yet. We will provide the next update within 30 minutes.
```

## ai_resolution_draft

```
## 1. RESOLUTION NOTE

The activation service experienced a critical incident lasting 6.1 minutes, during which the error rate reached 36.41% and cards were being declined at retail tills. The incident has now resolved; all alerts cleared at 2026-09-08T01:01:28Z.

## 2. STAKEHOLDER CLOSE-OUT

Card activation is now working normally after a 6-minute outage that caused cards to be declined at the till. The issue has cleared and we are monitoring the service.

## 3. POST-INCIDENT REVIEW SKELETON

**Impact**  
Duration: 6.1 minutes (2026-09-08T00:55:04Z to 2026-09-08T01:01:28Z). Error rate reached 36.41%; at peak, 22.6% of activation requests failed over a 2-minute window. Cards were being declined at retail tills. The 1-hour error rate was 14.4x the 0.5% budget, burning the monthly error budget at 26x normal rate. Top error reason: velocity_check_blocked (600 occurrences).

**Timeline**  
- 2026-09-08T00:52:30Z: Deploy of build 19 ("add velocity check for fraud team")
- 2026-09-08T00:54:48Z: Auto-rollback of build 19 (0.3 minutes before first alert)
- 2026-09-08T00:55:04Z: First alert (ActivationErrorBudgetBurnFast)
- 2026-09-08T00:55:10Z: ActivationHighErrorRate alert fired
- 2026-09-08T00:56:40Z: ActivationHighErrorRate alert resolved
- 2026-09-08T00:59:34Z: ActivationErrorBudgetBurnFast alert resolved
- 2026-09-08T01:01:28Z: Incident resolved

**Detection**  
Automated alerting detected the issue 19 seconds after the first alert fired. Auto-rollback had already occurred 0.3 minutes before the first alert.

**Root cause**  
Not yet known. The deploy of build 19 adding a velocity check occurred 2.6 minutes before alerting and was auto-rolled back 0.3 minutes before the first alert, but no responder actions recorded yet.

**What went well**  
Auto-rollback executed before the first alert fired.

**Follow-up actions**  
Not yet known.
```

## Meta

```
{
  "ai_meta": {
    "open": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "open",
      "input_tokens": 1542,
      "output_tokens": 258,
      "ok": true,
      "latency_ms": 6657
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 1822,
      "output_tokens": 709,
      "ok": true,
      "latency_ms": 17191
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 2945,
      "output_tokens": 597,
      "ok": true,
      "latency_ms": 11554
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 6
    },
    "deploys": {
      "ok": true,
      "latency_ms": 225
    },
    "logs": {
      "ok": true,
      "latency_ms": 129
    }
  }
}
```
