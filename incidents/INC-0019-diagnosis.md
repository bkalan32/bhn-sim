# INC-0019 — The fraud drill with the knowledge base in the prompt (Day 17) (generated 2026-09-11T20:11:48Z)

Record: `INC-1789157010-9d18`

## Timeline

```
  INC-1789157010-9d18  resolved  service=activation  severity=critical
  first alert 2026-09-11T20:03:10Z   opened 2026-09-11T20:03:30Z   resolved 2026-09-11T20:11:32Z   duration 8.0 min
  2026-09-11T20:03:30Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-11T20:03:31Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "ok"}, "latency_ms": 648}
  2026-09-11T20:03:31Z  note              [remediator] no remediation signature matched (ActivationHighErrorRate) — tier 3: human required. Context and hypothesis are on this record; the fix is not an action this platform can take on its own.
  2026-09-11T20:03:36Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 5369}
  2026-09-11T20:03:57Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 20771}
  2026-09-11T20:03:58Z  note              drill: fault injected at 2026-09-11T20:00:11Z (FRAUD_SVC_DOWN=true) — Day 17, with the knowledge base in the prompt
  2026-09-11T20:05:48Z  note              drill: fault removed at 2026-09-11T20:05:48Z (FRAUD_SVC_DOWN=false)
  2026-09-11T20:09:31Z  alerts_firing     ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T20:11:32Z  alerts_resolved   ActivationHighErrorRate(critical), ActivationErrorBudgetBurnFast(critical)
  2026-09-11T20:11:32Z  incident_resolved {"duration_min": 8.0}
  2026-09-11T20:11:46Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 14412}
```

## Context (enrichment)

```
  collected 2026-09-11T20:03:31Z  service=activation
  metrics      ok
    error_rate_pct           44.96
    p95_latency_s            0.48
    req_per_s                4.62
    health_score             0.0
    error_budget_burn_1h     9.28
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  ok
       611  fraud_service_timeout
        57  issuer_declined
```

## ai_hypothesis

```
## 1. WHAT WE KNOW

- **ActivationHighErrorRate** fired at 2026-09-11T20:03:10Z reporting error rate 100.0% over the last 2 minutes; cards are being declined at retail tills.
- Metrics snapshot at 20:03:31Z shows error_rate_pct 44.96%, p95_latency_s 0.48s, error_budget_burn_1h 9.28x, health_score 0.0.
- Top error reason: **fraud_service_timeout** (611 occurrences) vastly dominates issuer_declined (57).
- No deploys or rollbacks of activation in the last 6 hours.
- Request rate 4.62 req/s; the service is receiving traffic.

## 2. MOST LIKELY CAUSE

**Fraud dependency outage or timeout.** The evidence: fraud_service_timeout is the overwhelming reason (611 vs 57 issuer_declined), p95 latency is capped at 0.48s (consistent with the fail-fast timeout signature, not the 3s backend wait), error rate climbed to 100% then fell to ~45% by the snapshot, and no activation deploy occurred in the last 30 minutes. This matches **kb-001** exactly — the most-rehearsed pattern in the repository.

## 3. ALTERNATIVE

**A bad release (kb-002)** — but the evidence contradicts it: there is no deploy of activation in the last 6 hours, and the error reason is fraud_service_timeout (the dependency signature), not a new application-level reason like velocity_check_blocked. If a deploy annotation were present within 30 minutes before 20:03:10Z, kb-002 would be the lead.

## 4. SUGGESTED NEXT CHECKS

1. **Splunk reason breakdown over time:**  
   ```
   index=main app.service=activation app.status=error earliest=-15m 
   | timechart span=1m count by app.reason
   ```  
   Confirms fraud_service_timeout spiked at alert time and whether it persists.

2. **Prometheus p95 latency trend:**  
   ```
   histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))
   ```  
   A flat cap at ~0.3-0.5s confirms the fail-fast timeout; rising to 3s would indicate a different bottleneck.

3. **Check the fraud dependency knob (lab environment):**  
   ```
   kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -o 'FRAUD_SVC_DOWN[^}]*'
   ```  
   In production: consult the fraud provider's status page.

## 5. CONFIDENCE

**High.** All three context collectors succeeded (metrics 7ms, deploys 28ms, logs 612ms). The fraud_service_timeout dominance (611 vs 57), the capped p95 latency, the absence of a recent deploy, and the 100% error rate at alert time are the exact discriminators for kb-001. The only uncertainty is whether the dependency has already recovered (error rate dropped from 100% to 44.96% in 21 seconds).

## 6. KNOWLEDGE BASE

**Matches kb-001** (seen in INC-0001, INC-0007, INC-0008, INC-0009, INC-0011, INC-0018). The context already confirms: ActivationHighErrorRate firing, fraud_service_timeout dominates the reason histogram (611 >> 57), p95 latency 0.48s (the fail-fast cap), no activation deploy in 30 minutes. Remaining discriminating checks: the Splunk timechart to see if the timeout persists, the PromQL latency query to verify the 0.48s cap holds, and the FRAUD_SVC_DOWN environment variable (or the provider's status page in production). **Fix (tier 3):** Restore the fraud dependency — external, or in the lab set FRAUD_SVC_DOWN=false. No safe automated action; escalate to the provider/on-call with the reason histogram attached.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

ActivationHighErrorRate is firing (critical) for the activation service. Card activation flow is affected — cards are being declined at retail tills. The alert fired at 2026-09-11T20:03:10Z. Current error rate is 44.96% (alert summary reported 100.0% over the 2-minute window ending at alert time). Top error reason is fraud_service_timeout (611 occurrences), followed by issuer_declined (57). The runbook says to check Grafana 'Activation Service', then Splunk: `index=main app.service=activation app.status=error | stats count by app.reason`.

## 2. STAKEHOLDER UPDATE

Customers attempting to activate prepaid cards are experiencing failures — cards are being declined at the point of sale. The majority of errors are timeouts from the fraud check dependency. No responder actions recorded yet. Next update within 30 minutes.
```

## ai_resolution_draft

```
## 1. RESOLUTION NOTE

**Duration:** 8.0 minutes. Card activation experienced a critical error rate spike (100.0% at peak, 44.96% measured) starting 2026-09-11T20:03:10Z, causing cards to be declined at retail tills. Both ActivationHighErrorRate and ActivationErrorBudgetBurnFast alerts have now resolved as of 2026-09-11T20:11:32Z; activation service is currently operating normally.

## 2. STAKEHOLDER CLOSE-OUT

Card activation is now working normally after an 8-minute outage that caused cards to be declined at the till. The error rate has returned to acceptable levels and both critical alerts have cleared.

## 3. POST-INCIDENT REVIEW SKELETON

### Impact
- **Duration:** 8.0 minutes (2026-09-11T20:03:10Z to 2026-09-11T20:11:32Z)
- **Severity:** Critical
- **Customer impact:** Cards were being declined at retail tills due to activation failures
- **Error rate:** 100.0% at initial alert; 44.96% measured in metrics snapshot
- **Error budget burn:** 14.4x the 0.5% monthly budget (1h window); at that pace the 30-day budget would have been exhausted in approximately 2 days

### Timeline
- **2026-09-11T20:03:10Z** — ActivationHighErrorRate alert fired (error rate 100.0% over 2 minutes)
- **2026-09-11T20:03:30Z** — Incident opened
- **2026-09-11T20:03:31Z** — Context collected (metrics, deploys, logs)
- **2026-09-11T20:03:31Z** — Remediator note: no remediation signature matched; tier 3 human required
- **2026-09-11T20:07:40Z** — ActivationHighErrorRate resolved (error rate dropped below threshold)
- **2026-09-11T20:08:34Z** — ActivationErrorBudgetBurnFast alert fired (1h error rate 14.4x budget)
- **2026-09-11T20:10:34Z** — ActivationErrorBudgetBurnFast resolved
- **2026-09-11T20:11:32Z** — Incident resolved

### Detection
First alert at 2026-09-11T20:03:10Z; incident opened 20 seconds later at 2026-09-11T20:03:30Z.

### Root Cause
Not yet known. Top error reasons during the incident were fraud_service_timeout (611 occurrences) and issuer_declined (57 occurrences). No deploys or rollbacks of activation occurred in the 6 hours preceding the incident.

### What Went Well
Not yet known (no responder actions recorded yet).

### Follow-up Actions
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
      "input_tokens": 2188,
      "output_tokens": 219,
      "ok": true,
      "latency_ms": 5369
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 3913,
      "output_tokens": 1015,
      "ok": true,
      "latency_ms": 20771,
      "kb_matches": [
        {
          "id": "kb-001",
          "score": 12.5
        },
        {
          "id": "kb-002",
          "score": 5.5
        }
      ]
    },
    "resolved": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "resolved",
      "input_tokens": 3730,
      "output_tokens": 708,
      "ok": true,
      "latency_ms": 14412
    }
  },
  "context_meta": {
    "metrics": {
      "ok": true,
      "latency_ms": 7
    },
    "deploys": {
      "ok": true,
      "latency_ms": 28
    },
    "logs": {
      "ok": true,
      "latency_ms": 612
    }
  }
}
```
