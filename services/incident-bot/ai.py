"""
ai — the incident bot's drafting layer. The AI drafts; a human decides.

Everything here is best-effort. A failure returns an explanatory string, never an
exception into the caller's face, because the incident system must keep working when
the AI does not (no key, no network, model renamed, rate-limited). That rule is absolute.

Providers (AI_PROVIDER):
  anthropic  https://api.anthropic.com/v1/messages     needs ANTHROPIC_API_KEY
  ollama     {AI_BASE_URL}/api/chat                    local model, no key
  fake       canned text, no network                   unit tests and dry runs
  none       drafting disabled
  auto       (default) anthropic if a key is set, else ollama if AI_BASE_URL is set, else none

Differences from the PDF's ai.py (CORRECTIONS-DAY9.md):
  * a provider switch instead of "adapt _call by hand" for Ollama
  * the prompt gets the CURRENT TIME, so "when it started" and "how long" are computable
  * temperature 0.2 — evaluable output needs to be reproducible-ish
  * max_tokens 1500 — the resolved draft has three sections and a six-heading skeleton
  * returns text AND metadata (model, latency, tokens) so drafts can be graded and costed
  * Day 11 (after Eval 3): PLATFORM_FACTS — the inventory the model may reference — and
    the rollback-is-a-reversal rule. Both shared with tools/copilot.py.
"""

import json
import os
import time
import urllib.error
import urllib.request

import kb            # Day 17: the team's memory (kb/*.md via a ConfigMap at /kb), best-effort

# Day 11: the inventory the model may reference — and nothing else. Eval 3 found three
# of four "next checks" naming a namespace, a pod label and two metrics that do not
# exist here. Shared with tools/copilot.py (it imports this constant) so the bot and the
# copilot describe the same platform.
PLATFORM_FACTS = """PLATFORM FACTS (the complete inventory; nothing else exists):
- Kubernetes namespace `payments`: Deployments activation, egift, incident-bot, remediator
  (Day 12: tier-1 fixes, tier-2 proposals), loadgen (Day 21: the traffic, containers activation
  and egift, knob RATE_MULTIPLIER), mission-control (Day 21: the console and its API); CronJob
  settlement (a job every few minutes, metrics via Pushgateway). Namespace `monitoring`:
  Prometheus, Alertmanager, Grafana (kube-prometheus-stack, release kps). Namespace
  `logging`: Fluent Bit -> Splunk (Splunk itself runs outside the cluster). Namespace
  `tracing`: Tempo.
- Metrics: activation_requests_total{status="ok|error"}, activation_latency_seconds_bucket,
  egift_orders_total{status}, egift_order_latency_seconds_bucket,
  egift_step_latency_seconds_bucket{step="generate_code|activate|send_email"}, settlement_last_success_timestamp,
  settlement_last_run_timestamp, settlement_records_processed, settlement_last_run_status (1 = the last
  run succeeded, 0 = it failed), settlement_duration_seconds, and recording rules
  activation:health_score, egift:health_score, settlement:health_score, platform:health_score,
  activation:error_budget_burn_rate:1h|5m|6h, activation:sli_availability:ratio_rate5m|1h|6h.
  ALERTS{alertname,alertstate} lists alert state. Pod restarts: kube_pod_container_status_restarts_total.
  Traffic: loadgen_requests_total{target,outcome}, loadgen_target_rps, loadgen_rate_multiplier
  (0 = traffic turned off on purpose).
- Health scores (0-100, docs/health-score.md): activation = 60 x availability term + 40 x latency term
  (share of requests <= 300 ms); egift = 70 x order-success term + 30 x p95 order-latency term (full at
  <= 0.5 s, zero at >= 2.5 s); settlement = 70 if the last success is within 15 min + 30 if the last run
  processed > 0 records; platform = plain average of the three. Availability/success terms are linear
  from 100% of points at >= 99.5% to 0 at <= 95% ("ten error budgets below"): ~2% errors keeps two thirds
  of the term (activation ~80), ~3% keeps under half (egift ~60). A few percent of errors is a yellow
  or red score by design, not a mystery.
- Alerts (the complete custom set): ActivationHighErrorRate, ActivationNoTraffic,
  ActivationErrorBudgetBurnFast/Slow, ActivationLatencyBudgetBurn, EgiftHighErrorRate, EgiftHighLatency,
  EgiftStepSlow, SettlementJobFailed, SettlementStale, SettlementZeroRecords, IncidentBotDown,
  RemediatorDown, PaymentsPodCrashLooping, PlatformPodRestarting, plus the kube-prometheus-stack defaults
  (KubeJobFailed, CPUThrottlingHigh, KubeAPIErrorBudgetBurn, Watchdog, ...).
- Logs: Splunk index=main, JSON fields app.service (activation|egift|settlement|incident-bot),
  app.status (ok|error), app.reason (e.g. fraud_service_timeout, issuer_declined,
  velocity_check_blocked; settlement: db_unreachable, zero_records), app.store_id, app.trace_id,
  app.version, app.msg, app.level.
- Dependencies: the fraud check and the issuer call are outbound dependencies INSIDE
  activation; there is no fraud-service or issuer pod to inspect. egift calls activation
  (its "activate" step), so activation failures cascade into egift. Activations that egift
  triggers carry app.store_id=EGIFT — that is the eGift channel, not a retail store; retail
  stores look like STORE-0421.
- Baseline, not fault: activation's ERROR_RATE knob (default 0.02) fails a RANDOM 2% of requests
  with app.reason=issuer_declined — that is the simulated normal, not an issuer or program problem.
  Retail traffic picks one of STORE-0001..STORE-0500 at random per request, while every eGift
  activation is store_id=EGIFT, so EGIFT always tops a raw error count by volume alone: compare
  error RATES per store_id (errors / requests), never raw counts, before calling anything concentrated.
- Deploys go through Jenkins (deploy-service job) which annotates Grafana with tags
  deploy/rollback + the service name; images are tagged <service>:<build number>."""

SYSTEM = """You are an incident communications assistant for a payments platform.
You write from the incident record only. If information is not in the record, say
'not yet known'. Never invent metrics, causes, or times. Card activation and eGift
issuance are revenue-critical customer flows: activation errors mean cards are being
declined at retail tills; eGift errors mean corporate orders are failing.
Timestamps in the record are UTC. Quote them as given.

Rules added after grading real drafts (docs/ai-eval.md, Evals 0-2):
- Do not describe any action by the team or responders unless a timeline entry of type
  "note" records it. If there are no notes, write exactly: "no responder actions recorded
  yet". Never write that the team is "investigating" or "working to restore" on its own.
- Preserve the responder's hedging. If a note says "suspect", write "suspected"; do not
  upgrade a suspicion into a cause.
- Alert descriptions contain thresholds (e.g. "14.4x the budget"); thresholds are not
  measurements. Quote measured values from the alert's summary line or the metrics
  snapshot only.
- Quote duration_min exactly as given. Do not compute durations from timestamps.
- "What went well" may only cite facts on the record.

Rules added after Eval 3 (Day 10 drills):
- A rollback restores the previously running version. It is evidence that the preceding
  deploy was suspected; it is never itself a cause. Rate-window alerts (2-5 minute
  windows) can fire AFTER a rollback for errors that happened BEFORE it. If a deploy and
  its rollback both precede the alert, name the deploy.
- Reference only the inventory listed under PLATFORM FACTS. Do not invent namespaces,
  pod labels, metric names, log fields or services that are not listed there.

""" + PLATFORM_FACTS


DEFAULT_MODELS = {"anthropic": "claude-sonnet-4-5", "ollama": "llama3.2"}


def _cfg():
    provider = os.getenv("AI_PROVIDER", "auto").strip().lower()
    key = os.getenv("ANTHROPIC_API_KEY", "").strip()
    base = os.getenv("AI_BASE_URL", "").strip().rstrip("/")
    if provider == "auto":
        provider = "anthropic" if key else ("ollama" if base else "none")
    model = os.getenv("AI_MODEL", "").strip() or DEFAULT_MODELS.get(provider, "")
    if provider == "ollama" and model.startswith("claude"):
        model = DEFAULT_MODELS["ollama"]       # the manifest's default is an Anthropic name
    if provider == "fake":
        model = "fake"
    return provider, key, base, model


def enabled() -> bool:
    return _cfg()[0] in ("anthropic", "ollama", "fake")


def describe() -> dict:
    provider, key, base, model = _cfg()
    return {"provider": provider, "model": model, "key_present": bool(key), "base_url": base or None}


# ---------------------------------------------------------------- calls ------
def _anthropic(prompt, key, model, max_tokens):
    body = json.dumps({
        "model": model, "max_tokens": max_tokens, "temperature": 0.2, "system": SYSTEM,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=body,
        headers={"Content-Type": "application/json", "x-api-key": key,
                 "anthropic-version": "2023-06-01"})
    with urllib.request.urlopen(req, timeout=60) as r:
        d = json.loads(r.read())
    text = "".join(c.get("text", "") for c in d.get("content", []) if c.get("type") == "text")
    usage = d.get("usage", {})
    return text, {"input_tokens": usage.get("input_tokens"), "output_tokens": usage.get("output_tokens")}


def _ollama(prompt, base, model, max_tokens):
    body = json.dumps({
        "model": model, "stream": False,
        "options": {"temperature": 0.2, "num_predict": max_tokens},
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(f"{base}/api/chat", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:      # local models are slow on first load
        d = json.loads(r.read())
    return d.get("message", {}).get("content", ""), {
        "input_tokens": d.get("prompt_eval_count"), "output_tokens": d.get("eval_count")}


def _fake(prompt, kind):
    return (f"[fake {kind} draft]\n1. INTERNAL SUMMARY: drafted from the record only.\n"
            f"2. STAKEHOLDER UPDATE: the team is engaged; next update within 30 minutes.\n"
            f"(prompt was {len(prompt)} chars)"), {"input_tokens": 0, "output_tokens": 0}


def _call(prompt: str, kind: str, max_tokens: int = 1500):
    """Returns (text, meta). Never raises."""
    provider, key, base, model = _cfg()
    t0 = time.perf_counter()
    meta = {"provider": provider, "model": model, "kind": kind}
    try:
        if provider == "anthropic":
            text, usage = _anthropic(prompt, key, model, max_tokens)
        elif provider == "ollama":
            text, usage = _ollama(prompt, base, model, max_tokens)
        elif provider == "fake":
            text, usage = _fake(prompt, kind)
        else:
            return "(AI draft unavailable: no provider configured — set ANTHROPIC_API_KEY or AI_BASE_URL)", \
                   {**meta, "ok": False, "error": "no provider"}
        meta.update(usage or {})
        meta.update(ok=True, latency_ms=round((time.perf_counter() - t0) * 1000))
        return text.strip(), meta
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        meta.update(ok=False, error=f"HTTP {e.code}: {detail}", latency_ms=round((time.perf_counter() - t0) * 1000))
        return f"(AI draft unavailable: HTTP {e.code} from {provider} — {detail})", meta
    except Exception as e:  # noqa: BLE001 — the whole point: never let the AI break intake
        meta.update(ok=False, error=f"{type(e).__name__}: {e}", latency_ms=round((time.perf_counter() - t0) * 1000))
        return f"(AI draft unavailable: {type(e).__name__}: {e})", meta


# -------------------------------------------------------------- prompts ------
def _record(inc: dict) -> str:
    # Everything the model may use, nothing it should not. Drafts of its own are
    # excluded so a re-draft cannot quote an earlier draft as evidence. Notes that begin
    # with "drill:" are the lab's answer key (fault time, what was injected) — kept on the
    # record for the KPI table, hidden from the model so a diagnosis is a diagnosis.
    # (Found the hard way on Day 10: the first Drill A "diagnosed" from the note.)
    keep = {k: v for k, v in inc.items() if not k.startswith("ai_")}
    if isinstance(keep.get("timeline"), list):
        keep["timeline"] = [e for e in keep["timeline"]
                            if not (e.get("event") == "note" and str(e.get("text", "")).startswith("drill:"))]
    return json.dumps(keep, indent=2, default=str)


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def summarize_open(inc: dict):
    return _call(f"""A production incident just opened. The current time is {_now()}.
Write two things.

1. INTERNAL SUMMARY (3-4 sentences, for engineers joining the bridge):
what is firing, which service and customer flow is affected, when it started
(quote first_alert_at_iso), and what the alert runbooks say to check first.

2. STAKEHOLDER UPDATE (2-3 sentences, for business leadership, no jargon,
no alert names): what customers experience, what the team is doing,
when the next update will come (say: within 30 minutes).

Incident record:
{_record(inc)}""", "open")


def kb_matches(inc: dict) -> list:
    """Day 17: the KB entries whose symptoms overlap this ticket's words. Best-effort —
    a missing or malformed KB must never stop a hypothesis (the AI rule, applied to
    the AI's input)."""
    try:
        return kb.search(kb.query_from_incident(inc))
    except Exception:  # noqa: BLE001
        return []


def hypothesize(inc: dict):
    """Day 10: the junior diagnostician. Diagnosis only — never remediation.
    Day 17: with the team's memory in the prompt — matching KB entries, their
    discriminating checks, their fix and tier — and the instruction to cite the entry id."""
    ctx = inc.get("context") or {}
    opened = inc.get("first_alert_at_iso") or inc.get("opened_at_iso")
    matches = kb_matches(inc)
    kb_block = kb.render(matches)
    return _call(f"""A production incident just opened. The current time is {_now()}; the
first alert fired at {opened}. Using ONLY the incident record, its "context" section
(metrics snapshot, recent deploys with their age in minutes before the first alert, and
top error reasons from the logs), and the KNOWLEDGE BASE MATCHES below, write:

1. WHAT WE KNOW: 3-5 bullet facts drawn from the alerts, metrics snapshot, recent
deploys and top error reasons. Cite the numbers as they appear.
2. MOST LIKELY CAUSE: one hypothesis, with the evidence for it. If a DEPLOY of this
service occurred within 30 minutes BEFORE the first alert (minutes_before_first_alert
between 0 and 30), weigh it heavily. A deploy hours old, or one that happened AFTER the
alert (negative minutes), is not a cause. A ROLLBACK is never a cause: it restores the
previous version and tells you the deploy before it was suspected — if you see one, say
"already rolled back" and judge whether the metrics have recovered yet.
3. ALTERNATIVE: one other plausible cause and what evidence would confirm it.
4. SUGGESTED NEXT CHECKS: 2-3 specific commands or queries a responder should run,
using this platform's tools (kubectl, PromQL, Splunk search) and ONLY the inventory in
PLATFORM FACTS (namespace payments; the listed metrics and log fields). Diagnostic only.
5. CONFIDENCE: low / medium / high, one sentence why. If any context collector
reported an error, say which and lower your confidence accordingly.
6. KNOWLEDGE BASE: if a listed entry matches the evidence, say "matches <id> (seen in
<incidents>)", name which of its discriminating checks the context already confirms and
which remain to run, and state its fix and tier as the team's prior answer. If an entry
is listed but the evidence contradicts it (e.g. the reason histogram points elsewhere,
or a deploy is present), say so and which look-alike fits better. If no entry matches,
say "no KB match". Never cite an entry that is not listed below.

Do not propose remediation actions. Diagnosis only.

{kb_block}

Incident record:
{_record(inc)}""", "hypothesis", max_tokens=1400)


def summarize_resolved(inc: dict):
    return _call(f"""This incident just resolved. The current time is {_now()}.
Write three things.

1. RESOLUTION NOTE (2-3 sentences): duration (use duration_min), what was affected,
current status.
2. STAKEHOLDER CLOSE-OUT (2 sentences, plain language).
3. POST-INCIDENT REVIEW SKELETON with these headings filled in where the record
allows and marked 'not yet known' where it does not: Impact, Timeline,
Detection, Root cause, What went well, Follow-up actions.
Timeline entries of type "note" were written by a human responder during the
incident; treat them as first-hand observations and cite them.

Incident record:
{_record(inc)}""", "resolved")
