# INC-0009 — Drill A: dependency outage, enriched (generated 2026-09-12T17:16:52Z)

Record: `INC-1789233036-08d0`

## Timeline

```
  INC-1789233036-08d0  resolved  service=activation  severity=critical
  first alert 2026-09-12T17:10:10Z   opened 2026-09-12T17:10:36Z   resolved 2026-09-12T17:16:37Z   duration 6.0 min
  2026-09-12T17:10:36Z  alerts_firing     ActivationHighErrorRate(critical)
  2026-09-12T17:10:36Z  context_attached  {"collectors": {"metrics": "ok", "deploys": "ok", "logs": "error"}, "latency_ms": 12}
  2026-09-12T17:10:36Z  note              [remediator] no remediation signature matched (ActivationHighErrorRate) — tier 3: human required. Context and hypothesis are on this record; the fix is not an action this platform can take on its own.
  2026-09-12T17:10:41Z  ai_draft_attached {"draft": "open", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 5065}
  2026-09-12T17:11:06Z  ai_draft_attached {"draft": "hypothesis", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 25339}
  2026-09-12T17:11:07Z  note              drill: fault injected at 2026-09-12T17:06:29Z (FRAUD_SVC_DOWN=true)
  2026-09-12T17:12:59Z  note              drill: fault removed at 2026-09-12T17:12:59Z (FRAUD_SVC_DOWN=false)
  2026-09-12T17:16:37Z  alerts_resolved   ActivationHighErrorRate(critical)
  2026-09-12T17:16:37Z  incident_resolved {"duration_min": 6.0}
  2026-09-12T17:16:52Z  ai_draft_attached {"draft": "resolved", "ok": true, "model": "claude-sonnet-4-5", "latency_ms": 14711}
```

## Context (enrichment)

```
  collected 2026-09-12T17:10:36Z  service=activation
  metrics      ok
    error_rate_pct           48.01
    p95_latency_s            0.48
    req_per_s                4.61
    health_score             0.0
    error_budget_burn_1h     8.77
  deploys      ok
    no deploys or rollbacks of activation in the last 6h
  log reasons  URLError: <urlopen error [Errno 111] Connection refused>
    log lookup unavailable: URLError: <urlopen error [Errno 111] Connection refused>
```

## ai_hypothesis

```
## WHAT WE KNOW
- ActivationHighErrorRate firing at 2026-09-12T17:10:10Z: error rate is 100.0% over the last 2 minutes
- Metrics snapshot (5m window): error rate 48.01%, p95 latency 0.48s, request rate 4.61 req/s, health score 0.0
- Error budget burn rate 8.77x over 1h
- No deploys or rollbacks of activation in the last 6h
- Log collector failed with connection refused; top error reasons unavailable

## MOST LIKELY CAUSE
**Fraud dependency outage or timeout.** The error rate climbed to 100% in the 2-minute alert window; the 5-minute metrics snapshot shows 48.01% (same outage, two windows). P95 latency is capped at 0.48s, consistent with the fail-fast timeout signature (~0.3-0.5s) rather than stacking to 3s. No deploy in the last 30 minutes rules out a bad release. The pattern matches kb-001 except we cannot confirm the fraud_service_timeout reason in logs due to the Splunk collector failure.

## ALTERNATIVE
**A different activation dependency failure** (issuer API or database). The capped latency suggests a fail-fast timeout is working, but without the log reason histogram we cannot distinguish which dependency. Evidence to confirm: the Splunk query `index=main app.service=activation app.status=error earliest=-10m | stats count by app.reason` once Splunk is reachable — fraud_service_timeout >> issuer_declined confirms kb-001; issuer_declined dominant points to the issuer; db_unreachable would indicate the database.

## SUGGESTED NEXT CHECKS
1. **Restore log access and check error reasons:** `curl http://<splunk-host>:8089/...` or restart the log collector, then run `index=main app.service=activation app.status=error earliest=-10m | stats count by app.reason` in Splunk to see if fraud_service_timeout dominates (kb-001) or another reason appears.
2. **Check fraud service knob (lab environment):** `kubectl -n payments get deploy activation -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -o 'FRAUD_SVC_DOWN[^}]*'` — if FRAUD_SVC_DOWN=true, that is the cause.
3. **Verify activation pod health:** `kubectl -n payments get pods -l app=activation` and `kubectl -n payments logs -l app=activation --tail=50` to check for crash loops or startup errors that might explain the outage independent of dependencies.

## CONFIDENCE
**Medium.** The alert description (100% error rate), metrics snapshot (48% over 5m, capped p95 latency at 0.48s), no recent deploy, and error budget burn match kb-001's fraud dependency pattern closely. However, the **logs collector failed** (connection refused), so we cannot confirm the discriminating fraud_service_timeout reason that separates kb-001 from other causes. Confidence will rise to high once Splunk is reachable and the reason histogram confirms the pattern.

## KNOWLEDGE BASE
**Matches kb-001 (fraud dependency outage)** seen in INC-0001, INC-0007, INC-0008, INC-0009, INC-0011, INC-0018, INC-0019. Already confirmed: ActivationHighErrorRate firing, error rate ~100% in 2m window / 48% in 5m window (same outage, two windows), p95 latency capped at 0.48s (the fail-fast timeout signature), no deploy in last 30 min. **Remaining discriminating checks:** the Splunk reason histogram (fraud_service_timeout >> issuer_declined) and the FRAUD_SVC_DOWN environment variable. **Fix (tier 3):** Restore the fraud dependency — external provider or in the lab set FRAUD_SVC_DOWN=false. No safe automated action; escalate with the reason histogram once logs are available.
```

## ai_open_draft

```
## 1. INTERNAL SUMMARY

ActivationHighErrorRate is firing (critical). The activation service and card activation customer flow are affected. The alert fired at 2026-09-12T17:10:10.222Z. Error rate is 100.0% over the last 2 minutes; cards are being declined at the till. The runbook says to check Grafana 'Activation Service', then Splunk: index=main app.service=activation app.status=error | stats count by app.reason. Note: the log collector failed (Connection refused), so Splunk breakdown of error reasons is not yet available.

## 2. STAKEHOLDER UPDATE

Card activations are failing: customers attempting to activate prepaid cards are experiencing declines at retail tills. The error rate reached 100% starting at approximately 17:10 UTC. No responder actions recorded yet. Next update within 30 minutes.
```

## ai_resolution_draft

```
# 1. RESOLUTION NOTE

**INC-1789233036-08d0** resolved after **6.0 minutes**. ActivationHighErrorRate (error rate 100.0% at peak, 23.4% at resolution) affected card activation; cards were being declined at retail tills. Alert resolved at 2026-09-12T17:14:40Z; incident closed at 2026-09-12T17:16:37Z.

---

# 2. STAKEHOLDER CLOSE-OUT

The card activation issue that began at 17:10 UTC has resolved as of 17:14 UTC. Cards should now activate normally at the till.

---

# 3. POST-INCIDENT REVIEW SKELETON

## Impact
- **Duration**: 6.0 minutes (2026-09-12T17:10:36Z to 2026-09-12T17:16:37Z)
- **Affected service**: activation
- **Customer impact**: Cards were being declined at retail tills due to 100.0% error rate (peak), 23.4% at resolution
- **Metrics at incident open**: 48.01% error rate, 4.61 req/s, 0.48s p95 latency, health score 0.0, error budget burn 8.77x over 1h

## Timeline
- **2026-09-12T17:10:10Z**: ActivationHighErrorRate alert fired (error rate 100.0%)
- **2026-09-12T17:10:36Z**: Incident opened; remediator noted no remediation signature matched, human required
- **2026-09-12T17:14:40Z**: Alert resolved (error rate 23.4%)
- **2026-09-12T17:16:37Z**: Incident closed

## Detection
- Alert: ActivationHighErrorRate fired at 2026-09-12T17:10:10Z
- Detection lag: 26 seconds (alert to incident open)

## Root cause
Not yet known. No deploys or rollbacks of activation in the last 6 hours. Top error reason unavailable due to Splunk connection failure (URLError: Connection refused). No responder actions recorded yet.

## What went well
- Alert fired within the 2-minute rate window
- Remediator correctly escalated to human (no automated action matched)

## Follow-up actions
- Investigate root cause (error reasons unavailable due to log collector failure)
- Investigate Splunk connectivity issue that prevented error reason lookup during the incident
- Determine why error rate recovered without recorded human intervention
```

## Meta

```
{
  "ai_meta": {
    "open": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "open",
      "input_tokens": 2200,
      "output_tokens": 207,
      "ok": true,
      "latency_ms": 5065
    },
    "hypothesis": {
      "provider": "anthropic",
      "model": "claude-sonnet-4-5",
      "kind": "hypothesis",
      "input_tokens": 4003,
      "output_tokens": 974,
      "ok": true,
      "latency_ms": 25339,
      "kb_matches": [
        {
          "id": "kb-001",
          "score": 6.5
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
      "input_tokens": 2947,
      "output_tokens": 609,
      "ok": true,
      "latency_ms": 14711
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
      "ok": false,
      "error": "URLError: <urlopen error [Errno 111] Connection refused>",
      "latency_ms": 1
    }
  }
}
```
