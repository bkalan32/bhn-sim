#!/usr/bin/env python3
"""
daily_report — the platform briefs the on-call engineer, every morning. Day 18, Part C.

    python3 tools/daily_report.py                 gather -> one model call -> reports/daily/YYYY-MM-DD.md -> POST to the bot
    python3 tools/daily_report.py --dry           gather only; print the data the model would get (no API call, no store)
    python3 tools/daily_report.py --plan          also run `terraform plan` for the drift line (~2 min); otherwise DRIFT_STATUS env or "no data"
    python3 tools/daily_report.py --fetch DAY     copy a stored report (the Jenkins run's) from the bot into reports/daily/
    python3 tools/daily_report.py --day DAY       label the report with a different date (re-runs, evals)

Same shape as Days 9/10/11 — gather (read-only, the collectors that already degrade
gracefully), constrain (a tight brief, "no data" is a value, a word cap stated LAST), draft
(one call) — but on a SCHEDULE instead of on an event. Event-driven plus scheduled is the
complete shape of AI ops orchestration; both are now small and inspectable.

Every number the model sees is in the report's appendix, so a grader can trace each claim
(docs/ai-eval.md Eval 9). Boring days must produce boring reports: the eval checks that.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.getenv("LAB_ROOT", os.path.dirname(HERE))
sys.path.insert(0, HERE)
import copilot as cp   # noqa: E402  — the Day 11 hands: kubectl proxy, Prometheus, the bot, the API key
import kpis            # noqa: E402  — Day 18 Part B: the seven KPIs

BOT = cp.BOT_PROXY
REM = "/api/v1/namespaces/payments/services/remediator:8030/proxy"
WORD_CAP = 250
MAX_TOKENS = 520        # ~250 words + headings; the cap is restated last in the prompt (caps stated last survive best)

PROMPT = """Write the daily operations report for the payments platform from the data below.
Audience: the on-call engineer starting their day. Format, exactly these four sections:
1. HEADLINE: one sentence, overall state.
2. LAST 24H: incidents (id, service, duration, how remediated), deploys, notable metric movements. Facts only, cite numbers.
3. RISKS: error budgets below 50%, KPIs trending the wrong way, drift, anything still firing. If none, say so in one line.
4. NEEDS A HUMAN: decisions or follow-ups pending (open incidents, declined or pending remediations, incidents with no write-up or no KB entry).
Rules: no invented numbers; every number must appear in the data; 'no data' is an acceptable value and must be reported as such, never guessed around; a quiet day is reported as quiet in few words — do not manufacture concern; no advice beyond what the data implies.
Data:
{data}

Maximum {cap} words. Plain text with the four numbered headings; no markdown tables."""


# ----------------------------------------------------------------- gather ---
def q(expr, default=None):
    """One number from Prometheus via the copilot's hand (it returns {result: [{labels, value}]})."""
    try:
        d = cp.query_prometheus(expr)
        if "error" in d:
            return default
        r = d.get("result") or []
        return default if not r or r[0]["value"] is None else float(r[0]["value"])
    except Exception:  # noqa: BLE001
        return default


def q_by(expr, label):
    try:
        d = cp.query_prometheus(expr)
        return {x["labels"].get(label, "-"): x["value"] for x in (d.get("result") or []) if "error" not in d}
    except Exception:  # noqa: BLE001
        return {}


def r1(v):
    return None if v is None else round(v, 1)


def health():
    out = {}
    for name in ("platform", "activation", "egift", "settlement"):
        now = q(f"{name}:health_score"); ago = q(f"{name}:health_score offset 24h")
        out[name] = {"now": r1(now), "24h_ago": r1(ago), "delta": None if now is None or ago is None else r1(now - ago)}
    return out


def budgets():
    return {"availability_30d_pct": r1(q('100 * (1 - (1 - sum(increase(activation_requests_total{status="ok"}[30d])) / clamp_min(sum(increase(activation_requests_total[30d])), 1)) / 0.005)')),
            "latency_30d_pct": r1(q('100 * (1 - (1 - sum(increase(activation_latency_seconds_bucket{le="0.3"}[30d])) / clamp_min(sum(increase(activation_latency_seconds_count[30d])), 1)) / 0.01)')),
            "burn_rate_1h_now": r1(q("activation:error_budget_burn_rate:1h"))}


def settlement():
    age = q("time() - max(settlement_last_success_timestamp)")
    return {"last_success_minutes_ago": None if age is None else round(age / 60, 1),
            "last_run_records": q("max(settlement_records_processed)"),
            "failed_jobs_24h": q('count(kube_job_status_failed{namespace="payments", job_name=~"settlement.*"} > 0) or vector(0)'),
            "records_24h_sum_of_runs": q("sum(sum_over_time(settlement_records_processed[24h]))")}


def traffic():
    return {"activation_req_per_s": r1(q("sum(rate(activation_requests_total[5m]))")),
            "activation_error_pct_now": r1(q('100 * sum(rate(activation_requests_total{status="error"}[5m])) / clamp_min(sum(rate(activation_requests_total[5m])), 0.001)')),
            "activation_error_pct_24h_ago": r1(q('100 * sum(rate(activation_requests_total{status="error"}[5m] offset 24h)) / clamp_min(sum(rate(activation_requests_total[5m] offset 24h)), 0.001)')),
            "activation_p95_s_now": r1(q("histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))")),
            "egift_orders_per_s": r1(q("sum(rate(egift_orders_total[5m]))")),
            "egift_error_pct_now": r1(q('100 * sum(rate(egift_orders_total{status="error"}[5m])) / clamp_min(sum(rate(egift_orders_total[5m])), 0.001)'))}


def firing():
    try:
        d = cp.query_prometheus('ALERTS{alertstate="firing", alertname!="Watchdog"}')
        if "error" in d:
            return [{"error": "no data (Prometheus not answering)"}]
        return [{"alert": x["labels"].get("alertname"), "severity": x["labels"].get("severity"), "service": x["labels"].get("service", "-")} for x in d.get("result") or []]
    except Exception:  # noqa: BLE001
        return [{"error": "no data (Prometheus not answering)"}]


def platform_restarts():
    return {"restarts_24h": q('sum(increase(kube_pod_container_status_restarts_total{namespace=~"monitoring|logging|tracing|kube-system|newrelic"}[24h])) or vector(0)'),
            "pods_restarting_1h": q_by('sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace=~"monitoring|logging|tracing|kube-system|newrelic"}[1h])) > 0', "pod")}


def incidents(since):
    try:
        items = cp._raw_get(f"{BOT}/incidents") or []
    except Exception as e:  # noqa: BLE001
        return {"error": f"no data (bot: {e})"}, [], []
    recent, open_now = [], []
    for it in items:
        try:
            inc = cp._raw_get(f"{BOT}/incidents/{it['id']}")
        except Exception:  # noqa: BLE001
            continue
        if inc.get("status") == "open":
            open_now.append(inc)
        if inc.get("opened_at", 0) >= since or (inc.get("resolved_at") or 0) >= since:
            recent.append(inc)
    return None, recent, open_now


def remediation(since):
    try:
        hist = cp._raw_get(f"{REM}/actions") or []
        pend = cp._raw_get(f"{REM}/pending") or []
    except Exception as e:  # noqa: BLE001
        return {"error": f"no data (remediator: {e})"}, {}, []
    hist = hist if isinstance(hist, list) else hist.get("actions", hist.get("history", []))
    by_inc = {}
    for h in hist:
        ts = h.get("at_iso") or h.get("ts") or 0            # the remediator stamps at_iso (in-memory history, 200 entries)
        if isinstance(ts, str):
            ts = kpis.iso_to_ts(ts) or 0
        if ts and ts < since:
            continue
        by_inc.setdefault(h.get("incident"), []).append(f"{h.get('mode')}/{h.get('result')}" + (f" ({h.get('signature')})" if h.get("signature") else ""))
    pend = pend if isinstance(pend, list) else pend.get("pending", [])
    return None, by_inc, [{"incident": p.get("incident"), "signature": p.get("signature"), "action": p.get("action")} for p in pend]


def writeups_and_kb(recent_incs):
    """For each recent bot record: is there an incidents/INC-00NN.md that names it, and does a
    KB entry cite that INC? The README rule: every review updates a KB entry or says why not."""
    md = {}
    for f in glob.glob(os.path.join(LAB, "incidents", "INC-*.md")):
        try:
            md[os.path.basename(f)[:-3]] = open(f, encoding="utf-8").read()
        except Exception:  # noqa: BLE001
            pass
    cited = set()
    for f in glob.glob(os.path.join(LAB, "kb", "*.md")):
        try:
            m = re.search(r"^learned_from:\s*\[(.*?)\]", open(f, encoding="utf-8").read(), re.M)
            if m:
                cited |= {x.strip() for x in m.group(1).split(",") if x.strip()}
        except Exception:  # noqa: BLE001
            pass
    out = []
    for inc in recent_incs:
        wu = next((n for n, t in md.items() if inc["id"] in t), None)
        out.append({"incident": inc["id"], "write_up": wu or "none", "kb_cites_it": (wu in cited) if wu else False})
    return out


def drift(run_plan):
    env = os.getenv("DRIFT_STATUS", "").strip()
    if env:
        return env
    if not run_plan:
        return "no data (not checked this run; the Jenkins job plans first, or use --plan)"
    tf = os.path.join(LAB, "infra", "local", "tf.sh")
    try:
        r = subprocess.run([tf, "plan", "-input=false", "-no-color", "-lock=false", "-detailed-exitcode"], capture_output=True, text=True, timeout=300)
        return {0: "clean (terraform plan: no changes)", 2: "DRIFT (terraform plan exit 2 — read infra/local/plan.txt)"}.get(r.returncode, f"plan failed (exit {r.returncode})")
    except Exception as e:  # noqa: BLE001
        return f"no data (plan could not run: {type(e).__name__})"


def deploys():
    try:
        d = cp._raw_get(f"{BOT}/tools/deploys?hours=24") or {}
        out = {}
        for svc, rows in (d.get("deploys") or {}).items():
            if rows:
                out[svc] = [{"kind": r.get("kind"), "text": (r.get("text") or "")[:120], "at": r.get("at_iso")} if "text" in r else r for r in rows]
        return out or {"note": "no deploys or rollbacks in 24h"}
    except Exception as e:  # noqa: BLE001
        return {"error": f"no data (deploys: {e})"}


def gather(run_plan=False, days=7):
    now = time.time(); since = now - 86400
    err, recent, open_now = incidents(since)
    rerr, rem_by_inc, pending = remediation(since)
    inc_rows = []
    for inc in sorted(recent, key=lambda i: i.get("opened_at", 0)):
        inc_rows.append({"id": inc["id"], "service": inc.get("service"), "status": inc.get("status"),
                         "opened": inc.get("opened_at_iso"), "duration_min": inc.get("duration_min"),
                         "alerts": inc.get("alerts", []), "remediation": rem_by_inc.get(inc["id"], ["tier 3 / none recorded"]),
                         "hypothesis_cause": ([l.strip() for l in (inc.get("ai_hypothesis") or "").split("\n## 2.")[1].split("\n")[1:6] if l.strip()][:1] if "## 2." in (inc.get("ai_hypothesis") or "") else None)})
    try:
        k = kpis.summary(days)
    except Exception as e:  # noqa: BLE001
        k = {"error": f"no data (kpis: {type(e).__name__}: {e})"}
    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window": "last 24h unless stated",
        "health_scores": health(),
        "error_budgets": budgets(),
        "traffic_now_vs_24h_ago": traffic(),
        "settlement": settlement(),
        "incidents_24h": inc_rows if not err else err,
        "open_incidents_now": [i["id"] for i in open_now],
        "remediation_pending_proposals": pending if not rerr else rerr,
        "write_ups_and_kb": writeups_and_kb(recent) if recent else [],
        "deploys_24h": deploys(),
        "alerts_firing_now": firing(),
        "platform_restarts": platform_restarts(),
        "drift": drift(run_plan),
        f"kpis_{days}d": k,
    }


# ------------------------------------------------------------------ draft ---
def draft(data, key, model):
    body = json.dumps({"model": model, "max_tokens": MAX_TOKENS, "temperature": 0.1,
                       "messages": [{"role": "user", "content": PROMPT.format(data=json.dumps(data, indent=1), cap=WORD_CAP)}]}).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body,
                                 headers={"Content-Type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=90) as r:
        d = json.loads(r.read())
    text = "".join(b.get("text", "") for b in d.get("content", []) if b.get("type") == "text").strip()
    return text, {"model": d.get("model", model), "latency_ms": int((time.time() - t0) * 1000),
                  "input_tokens": d.get("usage", {}).get("input_tokens"), "output_tokens": d.get("usage", {}).get("output_tokens"),
                  "stop_reason": d.get("stop_reason")}


def numbers_in(text):
    return set(re.findall(r"\d+(?:\.\d+)?", text))


def trace_check(text, data):
    """Every number in the report should appear somewhere in the data (a coarse, honest check)."""
    blob = json.dumps(data)
    nums = numbers_in(text) - {"1", "2", "3", "4", "24", "30", "50", "7"}     # headings, windows, the 50 % rule
    missing = sorted(n for n in nums if n not in blob and n.rstrip("0").rstrip(".") not in blob)
    return missing


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry", action="store_true"); ap.add_argument("--plan", action="store_true")
    ap.add_argument("--fetch", metavar="DAY"); ap.add_argument("--day"); ap.add_argument("--no-store", action="store_true")
    ap.add_argument("--days", type=int, default=7, help="KPI window")
    a = ap.parse_args()
    outdir = os.path.join(LAB, "reports", "daily"); os.makedirs(outdir, exist_ok=True)
    if a.fetch:
        rec = cp._raw_get(f"{BOT}/reports/{a.fetch}")
        path = os.path.join(outdir, f"{a.fetch}.md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# Daily ops report — {a.fetch}\n\n_stored by the bot at {rec.get('stored_at_iso')} · {rec.get('words')} words · {rec.get('model')}_\n\n{rec['text']}\n\n## Data the model was given\n\n```json\n{json.dumps(rec.get('data'), indent=1)}\n```\n")
        print(f"fetched -> {path}"); return
    day = a.day or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    t0 = time.time()
    data = gather(run_plan=a.plan, days=a.days)
    print(f"gathered in {time.time() - t0:.1f}s: {len(data['incidents_24h']) if isinstance(data['incidents_24h'], list) else 'no'} incidents in 24h, "
          f"{len(data['alerts_firing_now'])} alerts firing, drift: {data['drift']}", file=sys.stderr)
    if a.dry:
        print(json.dumps(data, indent=1)); return
    key, src = cp._api_key()
    if not key:
        sys.exit("no API key — ./scripts/90-ai-secret.sh (or ANTHROPIC_API_KEY)")
    model = os.getenv("AI_MODEL") or cp._model_from_secret() or cp.DEFAULT_MODEL
    text, meta = draft(data, key, model)
    words = len(text.split()); missing = trace_check(text, data)
    meta.update({"words": words, "word_cap": WORD_CAP, "numbers_not_in_data": missing, "key_from": src})
    path = os.path.join(outdir, f"{day}.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"# Daily ops report — {day}\n\n_generated {data['generated_at']} · {meta['model']} · {words} words (cap {WORD_CAP}) · "
                f"{meta['latency_ms']} ms · numbers not traceable to the data: {missing or 'none'}_\n\n{text}\n\n"
                f"## Data the model was given\n\n```json\n{json.dumps(data, indent=1)}\n```\n")
    print(text); print()
    print(f"-- {words} words (cap {WORD_CAP}){'  OVER THE CAP' if words > WORD_CAP else ''} · {meta['latency_ms']} ms · "
          f"untraceable numbers: {', '.join(missing) if missing else 'none'} · {path}")
    if not a.no_store:
        try:
            r = cp._raw_post(f"{BOT}/reports", {"day": day, "text": text, "model": meta["model"], "data": data, "grade": None})
            print(f"-- stored on the bot: /reports/{day} ({r.get('words')} words)")
        except Exception as e:  # noqa: BLE001
            print(f"-- NOT stored on the bot: {e}")


if __name__ == "__main__":
    main()
