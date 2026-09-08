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
"""

import json
import os
import time
import urllib.error
import urllib.request

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
- "What went well" may only cite facts on the record."""

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


def hypothesize(inc: dict):
    """Day 10: the junior diagnostician. Diagnosis only — never remediation."""
    ctx = inc.get("context") or {}
    opened = inc.get("first_alert_at_iso") or inc.get("opened_at_iso")
    return _call(f"""A production incident just opened. The current time is {_now()}; the
first alert fired at {opened}. Using ONLY the incident record and its "context" section
(metrics snapshot, recent deploys with their age in minutes before the first alert, and
top error reasons from the logs), write:

1. WHAT WE KNOW: 3-5 bullet facts drawn from the alerts, metrics snapshot, recent
deploys and top error reasons. Cite the numbers as they appear.
2. MOST LIKELY CAUSE: one hypothesis, with the evidence for it. If a deploy or rollback
of this service occurred within 30 minutes BEFORE the first alert
(minutes_before_first_alert between 0 and 30), weigh it heavily. A deploy hours old, or
one that happened AFTER the alert (negative minutes), is not a cause.
3. ALTERNATIVE: one other plausible cause and what evidence would confirm it.
4. SUGGESTED NEXT CHECKS: 2-3 specific commands or queries a responder should run,
using this platform's tools (kubectl, PromQL, Splunk search). Diagnostic commands only.
5. CONFIDENCE: low / medium / high, one sentence why. If any context collector
reported an error, say which and lower your confidence accordingly.

Do not propose remediation actions. Diagnosis only.

Incident record:
{_record(inc)}""", "hypothesis", max_tokens=1200)


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
