# INC-0018 — EKS: the Day 10 dependency drill on a cloud the platform had never seen (generated 2026-09-11T00:07:17Z)

Record: `INC-1789084728-40d6`

## Timeline

```
  INC-1789084728-40d6  resolved  service=activation  severity=critical
  first alert 2026-09-10T23:58:33Z   opened 2026-09-10T23:58:48Z   resolved 2026-09-11T00:06:48Z   duration 8.0 min
  2026-09-10T23:58:48Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-10T23:58:48Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "error"}, "latency_ms": 48}
  2026-09-10T23:58:48Z  note              [remediator] no remediation signature matched (ActivationHighErrorRate) — tier 3: human required. Context and hypothesis are on this record; the fix is not an action this platform can take on its own.
  2026-09-10T23:58:54Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 5340}
  2026-09-10T23:59:15Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 21588}
  2026-09-10T23:59:20Z  note              drill: fault injected at 2026-09-10T23:55:45Z (FRAUD_SVC_DOWN=true) — on EKS (2 spot nodes, us-east-2); zero application or manifest changes
  2026-09-11T00:00:48Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T00:01:49Z  note              drill: fault removed at 2026-09-11T00:01:47Z (FRAUD_SVC_DOWN=false)
  2026-09-11T00:02:48Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T00:04:48Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T00:06:48Z  alerts_resolved   ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T00:06:48Z  incident_resolved {"duration_min": 8.0}
  2026-09-11T00:07:13Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 24857}
```

## Context (enrichment)

```
  collected 2026-09-10T23:58:48Z  service=activation
  metrics      ok
    error_rate_pct           43.71
    p95_latency_s            0.48
    req_per_s                3.44
    health_score             0.0
    error_budget_burn_1h     75.26
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  not configured
    log lookup unavailable: SPLUNK_URL not configured (scripts/100-enrich-config.sh)
```

## ai_hypothesis

```
## WHAT WE KNOW

- **ActivationHighErrorRate** firing since 2026-09-10T23:58:33Z; alert description reports "Error rate is 100.0% over the last 2 minutes."
- Metrics snapshot shows error_rate_pct=43.71%, req_per_s=3.44, p95_latency_s=0.48, health_score=0.0, error_budget_burn_1h=75.26.
- No deploys or rollbacks of activation in the last 6 hours.
- Top error reasons unavailable: log lookup reported "SPLUNK_URL not configured."
- Alert summary: "Cards are being declined at the till" — revenue-critical customer flow impacted.

## MOST LIKELY CAUSE

**Dependency failure (fraud check or issuer call).** With no recent deploy and a sudden jump to 100% errors (per alert description) followed by 43.71% in the snapshot, the most likely cause is an outbound dependency inside activation timing out or rejecting requests. The fraud service and issuer are both external calls that activation makes; either could cause wholesale failures. The 0.48s p95 latency is elevated but not catastrophic, suggesting requests are completing (with errors) rather than hanging indefinitely.

## ALTERNATIVE

**Database or internal service degradation.** If activation's own database or an internal component (e.g., configuration service, token generator) became unreachable, all requests would fail. Evidence would be: uniform error reasons in logs (once Splunk is configured), no correlation with specific store_id values, and no pattern in trace_id distribution. Check for pod restarts or resource exhaustion in the activation deployment.

## SUGGESTED NEXT CHECKS

1. **Check activation pod health and restarts:**  
   `kubectl -n payments get pods -l app=activation -o wide`  
   `kubectl -n payments describe deployment activation`  
   Look for recent restarts in `kube_pod_container_status_restarts_total{namespace="payments",pod=~"activation-.*"}`.

2. **Query current error rate and request volume:**  
   `rate(activation_requests_total{status="error"}[2m]) / rate(activation_requests_total[2m])` and `rate(activation_requests_total[2m])` in Prometheus to confirm whether the 100% error rate persists or has dropped to the 43.71% snapshot level.

3. **Configure Splunk and query error reasons (once SPLUNK_URL is set):**  
   `index=main app.service=activation app.status=error earliest=-5m | stats count by app.reason`  
   This will reveal whether errors are `fraud_service_timeout`, `issuer_declined`, or another reason, pinpointing the failing dependency.

## CONFIDENCE

**Medium.** The alert and metrics clearly show a critical error spike, and the absence of recent deploys narrows the field to dependency or infrastructure issues. However, the logs context collector failed ("SPLUNK_URL not configured"), so we lack the error reason breakdown that would definitively identify the failing component. Once logs are available, confidence will rise to high.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

ActivationHighErrorRate is firing (critical). The activation service and card activation customer flow are affected. The alert fired at 2026-09-10T23:58:33Z. The alert description states error rate is 100.0% over the last 2 minutes; the metrics snapshot shows 43.71% error rate and 75.26x error budget burn over 1h. The runbook says to check Grafana 'Activation Service', then Splunk: index=main app.service=activation app.status=error | stats count by app.reason. No deploys or rollbacks of activation in the last 6h.

## 2. STAKEHOLDER UPDATE

Card activations are failing: customers attempting to activate prepaid cards are experiencing declines at retail tills. The error rate spiked at 2026-09-10T23:58:33Z. No responder actions recorded yet. Next update within 30 minutes.
```

## ai_resolution_draft

```
# 1. RESOLUTION NOTE

INC-1789084728-40d6 resolved after 8.0 minutes. Activation service experienced a critical error rate spike (100.0% at peak, measured at 43.71% in the metrics snapshot) causing cards to be declined at retail tills. Alerts have cleared and the incident is now resolved.

# 2. STAKEHOLDER CLOSE-OUT

The card activation issue that began at 2026-09-10T23:58:33Z has been resolved as of 2026-09-11T00:06:48Z. Cards should now activate normally at the point of sale.

# 3. POST-INCIDENT REVIEW SKELETON

## Impact
- **Duration**: 8.0 minutes (2026-09-10T23:58:33Z to 2026-09-11T00:06:48Z)
- **Affected service**: activation
- **Customer impact**: Cards were being declined at retail tills due to activation failures
- **Error rate**: 100.0% (alert description), measured at 43.71% in metrics snapshot
- **Error budget burn**: 1h error rate was 14.4x the 0.5% budget; measured at 75.26x in metrics snapshot

## Timeline
- **2026-09-10T23:58:33Z**: ActivationHighErrorRate alert fired (error rate 100.0%)
- **2026-09-10T23:58:48Z**: Incident opened; remediator noted no automated remediation available
- **2026-09-10T23:58:56Z**: ActivationErrorBudgetBurnFast alert fired (105x burn rate)
- **2026-09-11T00:03:33Z**: ActivationHighErrorRate resolved (error rate dropped to 20.2%)
- **2026-09-11T00:06:48Z**: All alerts resolved; incident closed

## Detection
First alert at 2026-09-10T23:58:33Z via ActivationHighErrorRate; incident opened 15 seconds later at 2026-09-10T23:58:48Z.

## Root cause
Not yet known. No responder actions recorded yet. Log collection was unavailable during the incident (SPLUNK_URL not configured), preventing error reason analysis.

## What went well
Not yet known (no responder notes documenting investigation or resolution actions).

## Follow-up actions
- Investigate root cause (log collection was unavailable; SPLUNK_URL not configured)
- Determine what resolved the incident (no deploy, rollback, or manual intervention recorded)
- Fix log collection configuration to enable error reason analysis during future incidents
```

## Meta

```
{
  "ai_meta": {
    "open": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "open",
      "input_tokens": 2185,
      "output_tokens": 223,
      "ok": true,
      "latency_ms": 5340
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 2648,
      "output_tokens": 731,
      "ok": true,
      "latency_ms": 21588
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 4779,
      "output_tokens": 622,
      "ok": true,
      "latency_ms": 24857
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 22
    },
    "deploys": {
      "ok": true,
      "latency_ms": 25
    },
    "logs": {
      "ok": false,
      "error": "not configured",
      "latency_ms": 0
    }
  }
}
```
