# Day 4 — Corrections Log

Source: `day4secondserviceandtracing.pdf`
Verified 2 September 2026.

---

## [BUG] B1 — `helm install tempo grafana/tempo` fails: the repo was never added

Days 1–3 add `prometheus-community` and `fluent`. Nobody ever runs
`helm repo add grafana ...`. Step 1's first command returns
`Error: repo grafana not found`. `30-install-tracing.sh` adds it.

---

## [BUG] B2 — Tempo's HTTP port is 3200, not 3100

**Guide, Step 1:** Grafana datasource URL `http://tempo.tracing:3100`.

3100 is **Loki's** port. Tempo's HTTP API listens on **3200** (verified against the chart:
`tempo.server.http_listen_port | 3200`). "Save & test" fails with a connection refused and
nothing in Step 6 works. Fixed in `k8s/grafana-datasource-tempo.yaml`.

---

## [BUG] B3 — The datasource is added by clicking, so it dies with the pod

Grafana in kube-prometheus-stack has no persistent storage by default. A datasource added
through the UI vanishes the next time the pod restarts — which you've now seen happen twice.

**Substitute:** a ConfigMap labelled `grafana_datasource: "1"` in the `monitoring`
namespace. Grafana's sidecar loads it automatically. It lives in git and survives restarts.

---

## [PLATFORM] P1 — `sed -i ''` is macOS syntax

**Guide, Step 3:** `sed -i '' 's/activation:0.2/activation:0.3/' k8s/activation.yaml`

On GNU sed (Linux/WSL) `-i` takes an optional suffix *attached* to the flag, so the `''`
becomes the script and the `s/.../` becomes a filename:
`sed: can't read s/activation:0.2/activation:0.3/: No such file or directory`.

The manifest in this repo already says 0.3, so there's no sed at all — and `31-instrument-
activation.sh` refuses to run if it doesn't, so the file stays the source of truth (Day 3 B6).

---

## [BUG] B4 — The egift code as printed has inconsistent indentation → `IndentationError`

Two places:

```python
@app.get("/healthz")
   def healthz(): return {"status": "ok"}       # def indented under the decorator
```

and the `with tracer.start_as_current_span("generate_code"):` block sits deeper than the
`r = requests.post(...)` line that follows it at function level. Python rejects both. PDF
rendering artefacts, same class as the Day 2/3 YAML — but you can't paste it and run it.

---

## [BUG] B5 — `requests.post` with no exception handling: a dead dependency is invisible

**Guide, Step 4:**

```python
r = requests.post(ACTIVATION_URL, json={...}, timeout=10)
if r.status_code != 200:
    ...
```

If activation is *unreachable* — pod gone, DNS broken, network partition — `requests`
raises `ConnectionError` before `r` exists. FastAPI catches it and returns a bare 500.
**No metric increments. No log line is written.** The order counter, the error-rate panel
and Splunk all say "healthy" while every order fails.

You've met this shape three times now (Day 2 gauss, Day 2 loadgen, Day 3 Merge_Log). It is
the single most important habit in the series: **every failure path must be observable**.

**Substitute:** `try/except` around the call, mapping `Timeout` → 504
`activation_timeout` and any other `RequestException` → 502 `activation_unreachable`, each
with a metric, a log line and a reason. Timeout is 5s not 10 — a customer at a checkout is
not waiting ten seconds.

---

## [BUG] B6 — Every probe and scrape becomes a trace

Auto-instrumentation wraps *all* FastAPI routes. With two pods each scraped every 15s and
probed every 5–20s, Tempo fills with `GET /metrics` and `GET /readyz` spans. "Search by
service = activation" shows you the kubelet, not customers.

**Substitute:** `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS=healthz,readyz,metrics` in both
Deployments.

---

## [BUG] B7 — The OTEL endpoint is line-wrapped in the PDF

```
value: http://otel-opentelemetry-
collector.tracing:4317
```

One token. Pasted as printed, the exporter dials `http://otel-opentelemetry-` and every
trace is silently dropped. The Collector logs nothing because nothing arrives.

---

## [BUG] B8 — Day 4's code brings back Day 2/3's bugs, again

The egift snippet uses local-time timestamps with no zone, an unlabelled latency
histogram, and no floor on the delivery jitter. Same fixes as before, applied.

---

## [DESIGN] D1 — The dashboard *can* tell A from B, if you let it

The PDF's punchline is "the dashboard looked identical both times; only the trace told the
truth." True as written, because the only histogram is end-to-end. But that's a choice, not
a law. `egift_step_latency_seconds{step=...}` — one extra histogram — gives you a per-step
p95 panel where `activate` rises in A and `send_email` rises in B.

Traces are still the right tool for a *single* request. But a per-step metric gives you the
same answer as a **time series**, which is what you alert on. The dashboard carries both
panels side by side: "the panel that lies" and "the panel that tells the truth."

---

## [PLATFORM] P2 — Port-forward for egift → NodePort 30443

Same reason as Day 2: `port-forward` dies on every rollout, and Step 7 rolls egift twice.
Day 1's kind config mapped both 30080 and 30443; activation took the first, egift takes the
second. It's not HTTPS — it's just the other slot.

---

## Verified as correct

- The `egift → activation` trace structure and the waterfall shape. Reproduced exactly in
  `tools/tempojson.py`'s test against synthetic data, and cross-service propagation was
  confirmed live: one order, identical `trace_id` in both services' log lines.
- `otel-opentelemetry-collector` as the Service name for a release named `otel`.
- OTLP ports: 4317 gRPC, 4318 HTTP.
- `opentelemetry-bootstrap -a install` installing a lot — normal, and the reason the
  build helper runs it before freezing the lock file.
- The framing of Step 7. Two identical symptoms, two different teams to page. That is the
  most useful exercise in the series so far.
