# INC-0009 — Drill A: dependency outage, enriched (generated 2026-09-08T00:04:13Z)

Record: `INC-1788825339-a7fd`

## Timeline

```
  INC-1788825339-a7fd  resolved  service=activation  severity=critical
  first alert 2026-09-07T23:55:10Z   opened 2026-09-07T23:55:39Z   resolved 2026-09-08T00:03:57Z   duration 8.3 min
  2026-09-07T23:55:39Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-07T23:55:39Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "ok"}, "latency_ms": 75}
  2026-09-07T23:55:43Z  note              drill: fault injected at 2026-09-07T23:51:55Z (FRAUD_SVC_DOWN=true)
  2026-09-07T23:55:45Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 5203}
  2026-09-07T23:56:01Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 15173}
  2026-09-07T23:58:36Z  note              drill: fault removed at 2026-09-07T23:58:35Z (FRAUD_SVC_DOWN=false)
  2026-09-08T00:01:53Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:03:57Z  alerts_resolved   ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:03:57Z  incident_resolved {"duration_min": 8.3}
  2026-09-08T00:04:12Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 13961}
```

## Context (enrichment)

```
  collected 2026-09-07T23:55:39Z  service=activation
  metrics      ok
    error_rate_pct           41.9
    p95_latency_s            0.48
    req_per_s                4.35
    health_score             0.0
    error_budget_burn_1h     10.37
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  ok
    no error-status events for activation in the last 10m
```

## ai_hypothesis

```
## WHAT WE KNOW

- **ActivationHighErrorRate** firing since 2026-09-07T23:55:10Z: error rate is 100.0% over the last 2 minutes; alert threshold is >10%. Cards are being declined at the till.
- Metrics snapshot at 2026-09-07T23:55:39Z shows error_rate_pct: 41.9%, req_per_s: 4.35, p95_latency_s: 0.48, error_budget_burn_1h: 10.37.
- No deploys or rollbacks of activation in the last 6 hours.
- No error-status events for activation in the last 10 minutes (logs collector found none).
- Responder note at 2026-09-07T23:55:43Z: "drill: fault injected at 2026-09-07T23:51:55Z (FRAUD_SVC_DOWN=true)".

## MOST LIKELY CAUSE

**Injected fault simulating fraud service unavailability.** The responder recorded that FRAUD_SVC_DOWN=true was set at 2026-09-07T23:51:55Z, approximately 3 minutes before the first alert. Activation likely depends on the fraud service for card activation checks; if that dependency is down or timing out, activation requests would fail, matching the 100% error rate reported in the alert description and the 41.9% error rate in the metrics snapshot.

## ALTERNATIVE

**Upstream dependency failure (fraud service or another critical dependency) unrelated to the drill.** If this were a real production incident rather than a drill, a genuine outage of the fraud service or another required backend would produce identical symptoms. Confirming this would require checking the health and error rates of activation's upstream dependencies and reviewing network connectivity or timeout errors in activation's detailed logs.

## SUGGESTED NEXT CHECKS

1. **Splunk**: `index=main app.service=activation app.status=error earliest=-10m | stats count by app.reason` – identify the specific error reasons (the logs collector found no error events, but querying directly may reveal why).
2. **Splunk**: `index=main app.service=activation earliest=-10m | search "fraud" OR "timeout" OR "connection"` – look for fraud service call failures, timeouts, or connection errors.
3. **PromQL**: `rate(activation_dependency_errors_total{dependency="fraud"}[5m])` – check if activation is recording errors specifically for fraud service calls (adjust metric name to match your instrumentation).

## CONFIDENCE

**High.** All three context collectors succeeded. The responder's note explicitly documents a fault injection targeting the fraud service 3 minutes before the alert, and the timing aligns precisely with the observed error spike. The absence of recent deploys and the lack of error logs in the collector output are consistent with an externally injected fault rather than a code or configuration change.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

**ActivationHighErrorRate** is firing for the activation service, affecting card activation flow. Alert started at **2026-09-07T23:55:10Z**. The alert reports error rate at 100.0% over the last 2 minutes; current metrics snapshot shows 41.9% error rate at 4.35 req/s. Runbook says: check Grafana 'Activation Service', then Splunk: `index=main app.service=activation app.status=error | stats count by app.reason`. No deploys in the last 6h; no error-status log events found in the last 10m.

## 2. STAKEHOLDER UPDATE

Customers attempting to activate cards are experiencing failures—cards are being declined at retail tills. No responder actions recorded yet. We will provide the next update within 30 minutes.
```

## ai_resolution_draft

```
# 1. RESOLUTION NOTE

The activation service experienced a critical incident lasting 8.3 minutes, during which cards were being declined at retail tills due to error rates reaching 100%. The incident has now resolved; all alerts cleared at 2026-09-08T00:03:57Z.

# 2. STAKEHOLDER CLOSE-OUT

Card activation is now working normally after an 8-minute outage that caused cards to be declined at the till. This was a drill; a fault was injected at 23:51:55Z and removed at 23:58:35Z.

# 3. POST-INCIDENT REVIEW SKELETON

## Impact
- **Duration**: 8.3 minutes (2026-09-07T23:55:39Z to 2026-09-08T00:03:57Z)
- **Service**: Activation (revenue-critical customer flow)
- **Customer impact**: Cards were being declined at retail tills
- **Error rate**: 100.0% (peak), 41.9% (metrics snapshot at incident open)
- **Error budget burn**: 14.4x the 0.5% budget (1h measurement)

## Timeline
- **2026-09-07T23:51:55Z**: Drill fault injected (FRAUD_SVC_DOWN=true)
- **2026-09-07T23:55:10Z**: First alert fired (ActivationHighErrorRate)
- **2026-09-07T23:55:39Z**: Incident opened
- **2026-09-07T23:58:35Z**: Drill fault removed (FRAUD_SVC_DOWN=false)
- **2026-09-08T00:00:40Z**: ActivationHighErrorRate alert resolved
- **2026-09-08T00:03:04Z**: ActivationErrorBudgetBurnFast alert resolved
- **2026-09-08T00:03:57Z**: Incident resolved

## Detection
First alert at 2026-09-07T23:55:10Z; incident opened 29 seconds later at 2026-09-07T23:55:39Z.

## Root Cause
Drill: fault injected with FRAUD_SVC_DOWN=true at 2026-09-07T23:51:55Z.

## What Went Well
- Detection occurred within 4 minutes of fault injection
- No deploys or rollbacks were required (none had occurred in the prior 6 hours)

## Follow-Up Actions
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
      "input_tokens": 1335,
      "output_tokens": 205,
      "ok": true,
      "latency_ms": 5203
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 1711,
      "output_tokens": 682,
      "ok": true,
      "latency_ms": 15173
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 2938,
      "output_tokens": 595,
      "ok": true,
      "latency_ms": 13961
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 5
    },
    "deploys": {
      "ok": true,
      "latency_ms": 4
    },
    "logs": {
      "ok": true,
      "latency_ms": 65
    }
  }
}
```
