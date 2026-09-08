# INC-0009 — Drill A: dependency outage, enriched (generated 2026-09-08T00:41:33Z)

Record: `INC-1788827585-6b7f`

## Timeline

```
  INC-1788827585-6b7f  resolved  service=activation  severity=critical
  first alert 2026-09-08T00:32:40Z   opened 2026-09-08T00:33:05Z   resolved 2026-09-08T00:41:21Z   duration 8.3 min
  2026-09-08T00:33:05Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-08T00:33:05Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "ok"}, "latency_ms": 161}
  2026-09-08T00:33:09Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 4711}
  2026-09-08T00:33:23Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 12926}
  2026-09-08T00:33:25Z  note              drill: fault injected at 2026-09-08T00:30:04Z (FRAUD_SVC_DOWN=true)
  2026-09-08T00:35:09Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:35:58Z  note              drill: fault removed at 2026-09-08T00:35:58Z (FRAUD_SVC_DOWN=false)
  2026-09-08T00:37:12Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:39:17Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:41:21Z  alerts_resolved   ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-08T00:41:21Z  incident_resolved {"duration_min": 8.3}
  2026-09-08T00:41:31Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 9681}
```

## Context (enrichment)

```
  collected 2026-09-08T00:33:05Z  service=activation
  metrics      ok
    error_rate_pct           34.48
    p95_latency_s            0.48
    req_per_s                4.2
    health_score             0.0
    error_budget_burn_1h     18.22
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  ok
       435  fraud_service_timeout
        45  issuer_declined
```

## ai_hypothesis

```
## 1. WHAT WE KNOW

- **ActivationHighErrorRate** firing since 2026-09-08T00:32:40.222Z: error rate is 100.0% over the last 2 minutes; cards are being declined at the till.
- Current metrics snapshot shows error_rate_pct at 34.48%, req_per_s at 4.2, and error_budget_burn_1h at 18.22.
- Top error reason is **fraud_service_timeout** with 435 occurrences, followed by issuer_declined with 45 occurrences.
- No deploys or rollbacks of activation in the last 6 hours.
- P95 latency is 0.48s; health score is 0.0.

## 2. MOST LIKELY CAUSE

**Fraud service dependency failure or severe degradation.** The top error reason is fraud_service_timeout (435 occurrences), accounting for the vast majority of errors. The activation service appears to depend on a fraud check that is timing out, blocking card activations. The 0.48s p95 latency suggests requests are waiting for the fraud service before failing.

## 3. ALTERNATIVE

**Issuer API degradation affecting a subset of BINs.** The second error reason is issuer_declined (45 occurrences). Evidence to confirm: check if errors cluster by card BIN or issuer in Splunk (`index=main app.service=activation app.status=error | stats count by app.card_bin, app.issuer`), and verify fraud service health independently.

## 4. SUGGESTED NEXT CHECKS

1. **Check fraud service health**: `kubectl get pods -l app=fraud-service -n production` and query Prometheus for fraud service error rate: `rate(http_requests_total{service="fraud",status=~"5.."}[5m])`
2. **Analyze timeout distribution**: Splunk search `index=main app.service=activation app.reason=fraud_service_timeout | timechart span=1m count` to see when timeouts started.
3. **Verify fraud service latency**: PromQL query `histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{service="fraud"}[5m]))`

## 5. CONFIDENCE

**Medium.** All context collectors succeeded. The fraud_service_timeout error dominates the logs and aligns with the error spike, but we lack direct visibility into the fraud service's current state. No recent deploys rules out a code change in activation itself.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

**ActivationHighErrorRate** is firing for the activation service, which handles card activation (revenue-critical: activation errors mean cards are being declined at retail tills). The alert first fired at **2026-09-08T00:32:40Z** and reports an error rate of 100.0% over the last 2 minutes. The runbook says to check Grafana 'Activation Service', then Splunk: `index=main app.service=activation app.status=error | stats count by app.reason`. Top error reason is `fraud_service_timeout` (435 occurrences), followed by `issuer_declined` (45 occurrences); no recent deploys of activation in the last 6h.

---

## 2. STAKEHOLDER UPDATE

Customers attempting to activate cards are experiencing failures, with cards being declined at the till. The issue began at 2026-09-08T00:32:40Z; no responder actions recorded yet. We will provide the next update within 30 minutes.
```

## ai_resolution_draft

```
## 1. RESOLUTION NOTE

The activation service experienced a critical incident lasting 8.3 minutes. Error rates reached 100.0% over 2-minute windows, causing cards to be declined at retail tills. All alerts have now resolved as of 2026-09-08T00:41:21Z.

## 2. STAKEHOLDER CLOSE-OUT

Card activation has recovered after an 8-minute outage that caused cards to be declined at the till. The service is now operating normally.

## 3. POST-INCIDENT REVIEW SKELETON

**Impact**  
Duration: 8.3 minutes (first alert at 2026-09-08T00:32:40Z, resolved at 2026-09-08T00:41:21Z). Error rate reached 100.0% over 2-minute windows and 34.48% overall during the incident. The 1-hour error rate was 14.4x the 0.5% budget. Cards were being declined at retail tills. Request rate during the incident: 4.2 req/s.

**Timeline**  
- 2026-09-08T00:32:40Z: ActivationHighErrorRate alert fired (error rate 100.0%)
- 2026-09-08T00:33:04Z: ActivationErrorBudgetBurnFast alert fired (burning at 22x)
- 2026-09-08T00:37:40Z: ActivationHighErrorRate alert resolved
- 2026-09-08T00:40:34Z: ActivationErrorBudgetBurnFast alert resolved
- 2026-09-08T00:41:21Z: Incident resolved

**Detection**  
Automated alerting detected the incident 25 seconds before the incident record opened (first alert at 2026-09-08T00:32:40.222Z).

**Root cause**  
Not yet known. Top error reasons during the incident: fraud_service_timeout (435 occurrences), issuer_declined (45 occurrences). No deploys or rollbacks of activation in the 6 hours preceding the incident.

**What went well**  
No responder actions recorded yet.

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
      "input_tokens": 1359,
      "output_tokens": 243,
      "ok": true,
      "latency_ms": 4711
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 1639,
      "output_tokens": 598,
      "ok": true,
      "latency_ms": 12926
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 3806,
      "output_tokens": 528,
      "ok": true,
      "latency_ms": 9681
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 6
    },
    "deploys": {
      "ok": true,
      "latency_ms": 5
    },
    "logs": {
      "ok": true,
      "latency_ms": 150
    }
  }
}
```
