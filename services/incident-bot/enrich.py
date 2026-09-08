"""
enrich — the three lookups a human does in the first ten minutes, done by the bot at the
moment a ticket opens: current metrics (Prometheus), recent deploys (Grafana annotations),
top error reasons (Splunk). Attached to the record as `context`, then handed to the AI for
a diagnosis.

THE RULE: every collector catches its own exceptions and returns an explanatory stub.
Enrichment that takes down intake is worse than no enrichment. Nothing in this file may
raise into the caller.

Configuration (env; the secret `enrich-config` from scripts/100-enrich-config.sh supplies
the sensitive ones):
  PROM_URL          http://kps-kube-prometheus-stack-prometheus.monitoring:9090
  GRAFANA_URL       http://kps-grafana.monitoring
  GRAFANA_TOKEN     service-account token (Viewer) — never the admin password in code
  SPLUNK_URL        https://<splunk>:8089   (management port, not 8000/8088)
  SPLUNK_USER / SPLUNK_PASSWORD             REST auth = the admin login, NOT the HEC token
  SPLUNK_VERIFY     "false" for the lab's self-signed cert (flagged in README)
  ENRICH_TIMEOUT_S  per-call timeout (default 10; Splunk gets 2x)

Differences from the PDF's enrich.py (CORRECTIONS-DAY10.md):
  * no container IP and no base64 admin:password hardcoded in source — env + secret
  * Prometheus ratios use clamp_min in the denominator (0/0 = NaN = "no data", Day 3)
  * deploys are filtered to THIS service, include rollbacks, and carry an age in minutes
    relative to the incident's first alert — "a deploy 6 hours ago" and "a deploy 40
    seconds ago" must look different to the model
  * each collector reports ok/latency so a silent degradation shows up as a metric
  * Day 11: search_logs() — a validated, read-only, ad-hoc search for the copilot
"""

import base64
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

PROM = os.getenv("PROM_URL", "http://kps-kube-prometheus-stack-prometheus.monitoring:9090").rstrip("/")
GRAFANA = os.getenv("GRAFANA_URL", "http://kps-grafana.monitoring").rstrip("/")
GRAFANA_TOKEN = os.getenv("GRAFANA_TOKEN", "").strip()
SPLUNK = os.getenv("SPLUNK_URL", "").rstrip("/")
SPLUNK_USER = os.getenv("SPLUNK_USER", "admin")
SPLUNK_PASSWORD = os.getenv("SPLUNK_PASSWORD", "")
SPLUNK_VERIFY = os.getenv("SPLUNK_VERIFY", "false").strip().lower() != "false"
TIMEOUT = float(os.getenv("ENRICH_TIMEOUT_S", "10"))

# The same "does the request metric exist for this service?" map the Jenkinsfile carries.
QUERIES = {
    "activation": {
        "error_rate_pct": '100 * sum(rate(activation_requests_total{status="error"}[5m])) / clamp_min(sum(rate(activation_requests_total[5m])), 0.001)',
        "p95_latency_s": 'histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[5m])) by (le))',
        "req_per_s": 'sum(rate(activation_requests_total[5m]))',
        "health_score": 'activation:health_score',
        "error_budget_burn_1h": 'activation:error_budget_burn_rate:1h',
    },
    "egift": {
        "error_rate_pct": '100 * sum(rate(egift_orders_total{status="error"}[5m])) / clamp_min(sum(rate(egift_orders_total[5m])), 0.001)',
        "p95_order_latency_s": 'histogram_quantile(0.95, sum(rate(egift_order_latency_seconds_bucket[5m])) by (le))',
        "p95_activate_step_s": 'histogram_quantile(0.95, sum(rate(egift_step_latency_seconds_bucket{step="activate"}[5m])) by (le))',
        "orders_per_s": 'sum(rate(egift_orders_total[5m]))',
        "health_score": 'egift:health_score',
    },
    "settlement": {
        "minutes_since_success": '(time() - max(settlement_last_success_timestamp)) / 60',
        "last_records": 'max(settlement_records_processed)',
        "last_run_status": 'max(settlement_last_run_status)',
        "health_score": 'settlement:health_score',
    },
}


def _get(url, headers=None, timeout=None, data=None, verify=True):
    req = urllib.request.Request(url, headers=headers or {}, data=data)
    ctx = None if verify else ssl._create_unverified_context()  # noqa: S323 — lab-only, flagged
    with urllib.request.urlopen(req, timeout=timeout or TIMEOUT, context=ctx) as r:
        return json.loads(r.read())


def _timed(fn):
    t0 = time.perf_counter()
    try:
        out = fn()
        return out, {"ok": True, "latency_ms": round((time.perf_counter() - t0) * 1000)}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:200]
        return None, {"ok": False, "error": f"HTTP {e.code}: {detail}", "latency_ms": round((time.perf_counter() - t0) * 1000)}
    except Exception as e:  # noqa: BLE001 — the rule
        return None, {"ok": False, "error": f"{type(e).__name__}: {e}", "latency_ms": round((time.perf_counter() - t0) * 1000)}


# ------------------------------------------------------------ collectors ---
def _promq(query):
    url = f"{PROM}/api/v1/query?query={urllib.parse.quote(query)}"
    res = _get(url)["data"]["result"]
    if not res:
        return None
    v = float(res[0]["value"][1])
    return None if v != v else round(v, 2)          # NaN -> None


def metrics_snapshot(service):
    qs = QUERIES.get(service)
    if not qs:
        return {"note": f"no metric map for service '{service}'"}, {"ok": True, "latency_ms": 0}

    def run():
        return {k: _promq(q) for k, q in qs.items()}
    out, meta = _timed(run)
    return (out if out is not None else {"error": f"metrics unavailable: {meta.get('error')}"}), meta


def recent_deploys(service, since_ts, hours=6):
    """Deploys AND rollbacks for this service in the last `hours`, with age relative to
    `since_ts` (the incident's first alert). Negative age = after the alert."""
    def run():
        frm = int((since_ts - hours * 3600) * 1000)
        to = int((since_ts + 600) * 1000)             # a rollback may land just after
        url = f"{GRAFANA}/api/annotations?from={frm}&to={to}&tags={urllib.parse.quote(service)}&limit=20"
        headers = {"Authorization": f"Bearer {GRAFANA_TOKEN}"} if GRAFANA_TOKEN else {}
        anns = _get(url, headers=headers)
        out = []
        for a in sorted(anns, key=lambda x: x.get("time", 0), reverse=True):
            tags = a.get("tags", [])
            kind = "rollback" if "rollback" in tags else ("deploy" if "deploy" in tags else "annotation")
            t = a.get("time", 0) / 1000
            out.append({
                "kind": kind, "text": a.get("text"),
                "at_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)),
                "minutes_before_first_alert": round((since_ts - t) / 60, 1),
            })
        return out[:8]
    out, meta = _timed(run)
    if out is None:
        return [{"error": f"deploy lookup unavailable: {meta.get('error')}"}], meta
    if not out:
        return [{"note": f"no deploys or rollbacks of {service} in the last {hours}h"}], meta
    return out, meta


def top_log_reasons(service, minutes=10):
    """Splunk one-shot search over the REST API (8089), admin credentials, self-signed cert."""
    if not SPLUNK:
        return [{"error": "log lookup unavailable: SPLUNK_URL not configured (scripts/100-enrich-config.sh)"}], \
               {"ok": False, "error": "not configured", "latency_ms": 0}

    def run():
        q = (f'search index=main app.service={service} app.status=error earliest=-{minutes}m '
             f'| stats count by app.reason | sort -count')
        body = urllib.parse.urlencode({"search": q, "output_mode": "json", "exec_mode": "oneshot"}).encode()
        auth = base64.b64encode(f"{SPLUNK_USER}:{SPLUNK_PASSWORD}".encode()).decode()
        rows = _get(f"{SPLUNK}/services/search/jobs", headers={"Authorization": f"Basic {auth}"},
                    data=body, timeout=TIMEOUT * 2, verify=SPLUNK_VERIFY).get("results", [])
        return [{"reason": r.get("app.reason"), "count": int(r.get("count", 0))} for r in rows[:5]]
    out, meta = _timed(run)
    if out is None:
        return [{"error": f"log lookup unavailable: {meta.get('error')}"}], meta
    if not out:
        return [{"note": f"no error-status events for {service} in the last {minutes}m"}], meta
    return out, meta


# ------------------------------------------------- Day 11: ad-hoc search ---
# The copilot (tools/copilot.py) runs on your laptop, which is not on the platform
# network and does not hold the Splunk credential. The bot is, and does. So the bot
# exposes ONE read-only search endpoint and the copilot borrows its eyes, not its
# password. SPL is validated here: side-effect commands are refused, the time window is
# a parameter (never inline in the SPL — the PDF's own troubleshooting note), and the
# result set is capped.
SPL_SIDE_EFFECTS = ("delete", "outputlookup", "outputcsv", "outputtext", "sendemail", "sendalert",
                    "script", "collect", "mcollect", "meventcollect", "summaryindex", "tscollect",
                    "run", "map", "rest", "dbxquery", "savedsearch", "loadjob", "runshellscript")
_EARLIEST_RE = re.compile(r"^-\d{1,4}[smhd]$")
_TIME_TOKEN_RE = re.compile(r"\b(earliest|latest)\s*=\s*\S+", re.I)


def validate_spl(spl: str, earliest: str = "-30m"):
    """Returns (effective_spl, earliest) or raises ValueError with the reason."""
    s = (spl or "").strip()
    if not s:
        raise ValueError("empty search")
    if s.lower().startswith("search "):
        s = s[7:].strip()
    if s.startswith("|"):
        raise ValueError("generating commands (a leading '|') are not permitted; start with a search")
    for cmd in SPL_SIDE_EFFECTS:
        if re.search(r"\|\s*" + cmd + r"\b", s, re.I):
            raise ValueError(f"'| {cmd}' is not permitted: read-only searches only")
    if _TIME_TOKEN_RE.search(s):
        s = _TIME_TOKEN_RE.sub("", s)          # one place for time bounds: the parameter
        s = re.sub(r"\s{2,}", " ", s).strip()
    if not re.search(r"\bindex\s*=", s, re.I):
        s = "index=main " + s
    if len(s) > 2000:
        raise ValueError("search too long")
    e = (earliest or "-30m").strip()
    if not _EARLIEST_RE.match(e):
        raise ValueError("earliest must look like -5m, -2h or -1d")
    return s, e


def search_logs(spl: str, earliest: str = "-30m", limit: int = 50):
    """Splunk one-shot over REST, read-only. Never raises."""
    try:
        s, e = validate_spl(spl, earliest)
    except ValueError as ex:
        return {"rows": [], "count": 0, "spl": spl, "earliest": earliest,
                "meta": {"ok": False, "error": f"rejected: {ex}", "latency_ms": 0}}
    if not SPLUNK:
        return {"rows": [], "count": 0, "spl": s, "earliest": e,
                "meta": {"ok": False, "error": "SPLUNK_URL not configured (scripts/100-enrich-config.sh)", "latency_ms": 0}}
    limit = max(1, min(int(limit or 50), 200))

    def run():
        body = urllib.parse.urlencode({"search": "search " + s, "output_mode": "json",
                                       "exec_mode": "oneshot", "earliest_time": e, "count": limit}).encode()
        auth = base64.b64encode(f"{SPLUNK_USER}:{SPLUNK_PASSWORD}".encode()).decode()
        rows = _get(f"{SPLUNK}/services/search/jobs", headers={"Authorization": f"Basic {auth}"},
                    data=body, timeout=TIMEOUT * 2, verify=SPLUNK_VERIFY).get("results", [])
        # raw events carry Splunk's internal fields — keep what a responder reads
        keep = []
        for r in rows[:limit]:
            keep.append({k: v for k, v in r.items() if not k.startswith("_") or k in ("_time", "_raw")})
        return keep
    out, meta = _timed(run)
    return {"rows": out or [], "count": len(out or []), "spl": s, "earliest": e, "meta": meta}


# --------------------------------------------------------------- entry -----
def enrich(service, since_ts=None):
    """Never raises. Returns (context, collectors_meta)."""
    since_ts = since_ts or time.time()
    service = service or "activation"
    metrics, m1 = metrics_snapshot(service)
    deploys, m2 = recent_deploys(service, since_ts)
    reasons, m3 = top_log_reasons(service)
    ctx = {
        "collected_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "service": service,
        "metrics": metrics,
        "recent_deploys": deploys,
        "top_error_reasons": reasons,
    }
    return ctx, {"metrics": m1, "deploys": m2, "logs": m3}


def configured():
    return {"prometheus": PROM, "grafana": GRAFANA, "grafana_token": bool(GRAFANA_TOKEN),
            "splunk": SPLUNK or None, "splunk_verify": SPLUNK_VERIFY, "timeout_s": TIMEOUT}
