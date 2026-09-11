# INC-0009 — Drill A: dependency outage, enriched (generated 2026-09-11T19:01:22Z)

Record: `INC-1789153026-7443`

## Timeline

```
  INC-1789153026-7443  resolved  service=activation  severity=critical
  first alert 2026-09-11T18:56:40Z   opened 2026-09-11T18:57:06Z   resolved 2026-09-11T19:01:09Z   duration 4.0 min
  2026-09-11T18:57:06Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-11T18:57:06Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "ok"}, "latency_ms": 93}
  2026-09-11T18:57:08Z  note              [remediator] no remediation signature matched (ActivationHighErrorRate) — tier 3: human required. Context and hypothesis are on this record; the fix is not an action this platform can take on its own.
  2026-09-11T18:57:12Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 5172}
  2026-09-11T18:57:27Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 15461}
  2026-09-11T18:57:28Z  note              drill: fault injected at 2026-09-11T18:53:25Z (FRAUD_SVC_DOWN=true)
  2026-09-11T18:58:55Z  note              drill: fault removed at 2026-09-11T18:58:55Z (FRAUD_SVC_DOWN=false)
  2026-09-11T19:01:09Z  alerts_resolved   ActivationHighErrorRate(critical)
  2026-09-11T19:01:09Z  incident_resolved {"duration_min": 4.0}
  2026-09-11T19:01:21Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 11830}
```

## Context (enrichment)

```
  collected 2026-09-11T18:57:06Z  service=activation
  metrics      ok
    error_rate_pct           52.22
    p95_latency_s            0.48
    req_per_s                4.16
    health_score             0.0
    error_budget_burn_1h     13.96
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  ok
       941  fraud_service_timeout
        35  issuer_declined
```

## ai_hypothesis

```
## WHAT WE KNOW
- ActivationHighErrorRate firing at 2026-09-11T18:56:40Z: error rate is 100.0% over the last 2 minutes; cards are being declined at the till.
- Metrics snapshot at 2026-09-11T18:57:06Z: error_rate_pct 52.22%, health_score 0.0, error_budget_burn_1h 13.96x the budget.
- Top error reason: fraud_service_timeout (941 occurrences), followed by issuer_declined (35 occurrences).
- No deploys or rollbacks of activation in the last 6 hours.
- Request rate 4.16 req/s, p95 latency 0.48s.

## MOST LIKELY CAUSE
The fraud check dependency (an outbound call inside activation) is timing out. Evidence: fraud_service_timeout is the dominant error reason (941 vs. 35 for issuer_declined), and the error rate spiked to 100% over 2 minutes with no recent code changes. The fraud service is external to the cluster; a network issue, capacity problem, or outage on that service would cause widespread activation failures.

## ALTERNATIVE
A configuration change or infrastructure issue affecting activation's ability to reach the fraud service (DNS, network policy, credentials). Confirming evidence would be: activation pod logs showing connection errors or DNS resolution failures in app.msg fields; Kubernetes events for the activation deployment; or correlation with other services that call the same fraud endpoint.

## SUGGESTED NEXT CHECKS
1. **Splunk**: `index=main app.service=activation app.status=error app.reason=fraud_service_timeout earliest=-5m | head 20` — examine app.msg and app.trace_id fields for timeout details (connection vs. read timeout, endpoint, duration).
2. **PromQL**: `rate(activation_requests_total{status="error"}[5m])` and `rate(activation_requests_total{status="ok"}[5m])` — confirm whether ALL requests are failing or only a subset.
3. **kubectl**: `kubectl -n payments logs deployment/activation --tail=50 --timestamps` — check for recent connection errors, DNS failures, or credential issues in the fraud service call path.

## CONFIDENCE
**Medium**. All three context collectors succeeded. The fraud_service_timeout pattern is clear and dominant, but we have no visibility into the fraud service itself (it's external). The absence of recent deploys rules out a code change, but we cannot yet confirm whether the issue is in the fraud service, the network path, or activation's configuration for reaching it.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

ActivationHighErrorRate is firing (critical). The activation service and card activation customer flow are affected. The alert fired at 2026-09-11T18:56:40Z. The runbook says to check Grafana 'Activation Service', then Splunk: `index=main app.service=activation app.status=error | stats count by app.reason`. Current error rate is 52.22% with 941 fraud_service_timeout errors and 35 issuer_declined errors in recent logs; no deploys in the last 6 hours.

## 2. STAKEHOLDER UPDATE

Customers attempting to activate prepaid cards are experiencing failures at retail tills starting at 18:56 UTC. The majority of errors appear related to fraud check timeouts. The team will provide the next update within 30 minutes.
```

## ai_resolution_draft

```
## 1. RESOLUTION NOTE

The activation service experienced a critical outage lasting 4.0 minutes. Error rate reached 100.0% at peak, with 941 activations failing due to fraud_service_timeout and 35 due to issuer_declined. The ActivationHighErrorRate alert has resolved as of 2026-09-11T19:00:40Z; the service is now operational.

## 2. STAKEHOLDER CLOSE-OUT

Card activation was unavailable for 4 minutes starting at 18:56 UTC, causing cards to be declined at retail tills. The service has recovered and activations are processing normally.

## 3. POST-INCIDENT REVIEW SKELETON

**Impact**  
Duration: 4.0 minutes (2026-09-11T18:56:40Z to 2026-09-11T19:00:40Z). Error rate peaked at 100.0%, later measured at 52.22% over the incident window. 941 activations failed with fraud_service_timeout; 35 failed with issuer_declined. Cards were declined at the till during this period.

**Timeline**  
- 2026-09-11T18:56:40Z: ActivationHighErrorRate alert fired (error rate 100.0%)
- 2026-09-11T18:57:06Z: Incident opened
- 2026-09-11T18:57:08Z: Remediator determined no automated fix available; human required
- 2026-09-11T19:00:40Z: Alert resolved (error rate 22.7%)
- 2026-09-11T19:01:09Z: Incident closed

**Detection**  
ActivationHighErrorRate alert at 2026-09-11T18:56:40Z, 26 seconds before incident opened.

**Root cause**  
Not yet known. The fraud check dependency (an outbound call inside the activation service) timed out in 941 cases. No deploys or rollbacks of activation occurred in the 6 hours preceding the incident. No responder actions recorded yet.

**What went well**  
Alert fired promptly. Context collection completed in 93ms.

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
      "input_tokens": 2186,
      "output_tokens": 197,
      "ok": true,
      "latency_ms": 5172
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 2650,
      "output_tokens": 614,
      "ok": true,
      "latency_ms": 15461
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 2933,
      "output_tokens": 526,
      "ok": true,
      "latency_ms": 11830
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 6
    },
    "deploys": {
      "ok": true,
      "latency_ms": 4
    },
    "logs": {
      "ok": true,
      "latency_ms": 83
    }
  }
}
```
