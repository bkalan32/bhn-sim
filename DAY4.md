# Day 4 — A Second Service and Distributed Tracing

Adapted from `day4secondserviceandtracing.pdf`. Changes in **[CORRECTIONS-DAY4.md](CORRECTIONS-DAY4.md)**.

> Two things that would stop you cold in the PDF: the Grafana datasource points at port
> **3100** (Loki's — Tempo is **3200**), and `helm install tempo grafana/tempo` fails because
> the grafana repo was never added. Both handled by the scripts.

---

## Why today exists

A single service is not a distributed system. Real incidents happen at the boundaries: A is
slow because B is slow because C's database is slow. Metrics tell you A is slow. Logs tell
you A logged a timeout. **Neither tells you where in the chain the time went.** That's what
tracing is for.

## The business flow

**eGift issuance.** A corporate customer orders 200 digital gift cards for their sales team.
For each: generate a code → activate it (the Day 2 service) → deliver by email.

When a customer says *"my eGift orders take 30 seconds,"* the question on the bridge is: code
generation, activation, or email? Tracing answers that in one screen.

---

## Step 1 — Trace backend + Collector

```bash
./scripts/30-install-tracing.sh
```

Installs **Tempo** (stores traces, plugs into your Grafana) and the **OpenTelemetry
Collector** (apps send here, it forwards to Tempo), then registers Tempo as a Grafana
datasource **as code** — a ConfigMap Grafana's sidecar loads, which survives restarts. The
PDF has you click through Connections → Data sources, which vanishes with the pod.

Why a Collector at all, when apps could send straight to Tempo: in real platforms it sits in
the middle so you can swap backends, sample and enrich without touching application code.

Vocabulary: **OTLP** is the OpenTelemetry protocol. **4317** is gRPC, **4318** is HTTP. You'll
see these two ports everywhere in observability work.

---

## Step 2 — Instrument activation (v0.3)

```bash
./scripts/31-instrument-activation.sh
```

You don't write tracing code. `opentelemetry-instrument` wraps the process and auto-
instruments FastAPI and outgoing HTTP. The only app change is three lines in
`JsonFormatter` that put the current `trace_id` on every log line — that's what makes
logs and traces join later.

Also set: `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS=healthz,readyz,metrics`. Without it every
probe and scrape becomes a trace and Tempo fills with kubelet noise.

---

## Step 3 — Build the eGift service

```bash
./scripts/32-build-egift.sh
```

Read `services/egift/app.py`. Two things are new vs activation:

- **`requests.post` to activation.** Auto-instrumentation wraps this and injects
  `traceparent` headers, so activation's span becomes a child of this request's trace. No
  code for that part.
- **Manual spans** — `tracer.start_as_current_span("generate_code")`. Auto-instrumentation
  only sees HTTP boundaries; internal steps you care about, you name yourself. Attributes
  like `email.provider` become searchable.

One fix worth understanding:

> **The PDF's `requests.post` has no `try/except`.** If activation is *unreachable* — not
> erroring, gone — `requests` raises before `r` exists, FastAPI returns a bare 500, and
> **neither the metric nor the log records it**. Dead dependency, invisible to everything you
> built on Days 2–3. Ours maps timeout → 504 and unreachable → 502, each observable.

The script also checks egift can reach `activation.payments:8000` *before* you go looking
for traces — the PDF lists that as troubleshooting item #3; better to know up front.

---

## Step 4 — Two customer types

**Terminal #6:**

```bash
cd ~/bhn-sim && ./scripts/33-loadgen-egift.sh
```

Stores activating physical cards (terminal #2) and corporates ordering eGifts (terminal #6).
eGift fans out to activation, so activation's traffic rises by the same amount — expected.

---

## Step 5 — Look at a trace

```bash
./scripts/34-verify-traces.sh
```

Finds a recent egift trace, prints the waterfall in your terminal, and **asserts both
services appear in it**:

```
  egift POST /orders              ████████████████████████████   180ms
    egift generate_code           ██                              10ms
    egift POST                    ████████████████                90ms
      activation POST /activate   ██████████████                  85ms
    egift send_email              ████████                        40ms
```

Read it top to bottom. One customer request, two services, and exactly where the 180ms went.
**This is the view that ends the "is it us or them?" argument on an incident bridge.**

Then the same in Grafana: **Explore → Tempo → Search → Service Name: egift → Run**. Click
any trace. Same waterfall, prettier.

**Now the join.** Copy the trace ID (the script saved one to `checkpoints/`) and in Splunk:

```spl
index=main app.trace_id=<paste>
```

Both services' log lines for that single request, together. In a real company this
correlation is worth a lot of money in reduced diagnosis time.

---

## Step 6 — Two incidents that look the same on a dashboard

Import `dashboards/egift.json` first (Dashboards → New → Import). Note it has **two** p95
panels: end-to-end ("the panel that lies") and per-step ("the panel that tells the truth").

**Experiment A — the dependency is slow:**

```bash
./scripts/35-experiment-latency.sh A
```

Activation `BASE_LATENCY_MS` 80 → 800. eGift p95 climbs to ~1s. The script prints a live
waterfall: **activation is the wide bar.** `ActivationHighLatency` fires — expected.

**Experiment B — our own step is slow:**

```bash
./scripts/35-experiment-latency.sh B
```

eGift `DELIVERY_DELAY_MS` 40 → 800. eGift p95 climbs to ~1s — **the same number**. The
waterfall: **`send_email` is the wide bar, activation is normal.** No alert fires, because
nothing watches email yet.

**The end-to-end panel looked identical both times. The trace told the truth in five
seconds.** And — this is the part the PDF doesn't say — so did the per-step panel, as a time
series, which is what you can *alert* on.

Fill in `incidents/INC-0002.md` and `INC-0003.md`. The follow-up in each is *who you'd page*:
A → the activation team. B → the email provider. Paging the wrong one wastes a person and
delays the fix.

---

## Step 7 — Runbook and commit

README already covers Tempo in Grafana, search by service, trace ID → Splunk, and the new
knobs. Then:

```bash
git add -A && git commit -m "Day 4: egift service, OpenTelemetry, Tempo, INC-0002/0003" && git push
./scripts/38-checkpoint-day4.sh
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `repo grafana not found` | Repo never added | `30-install-tracing.sh` adds it |
| Tempo datasource "connection refused" | Port 3100 in URL | It's 3200 |
| No traces in Tempo | Collector can't reach Tempo | `kubectl logs -n tracing -l app.kubernetes.io/name=opentelemetry-collector` |
| Traces from egift, none from activation | Not rebuilt under `opentelemetry-instrument`, or OTEL env missing | `31-instrument-activation.sh`; `kubectl describe pod` shows env |
| egift 502 for everything | Can't reach `activation.payments:8000` | `32-build-egift.sh` tests this; `kubectl get svc -n payments` |
| Tempo full of `GET /metrics` spans | Excluded URLs not set | `OTEL_PYTHON_FASTAPI_EXCLUDED_URLS` |
| `sed: can't read s/...` | macOS `sed -i ''` | GNU sed: `sed -i 's/…/'` — but the manifest is already right |
| `localhost:30443` unreachable | Cluster created without the Day 1 kind config | `kind/bhn-sim-cluster.yaml` maps it; recreate, or port-forward 8002:8010 |

---

## What's next

Day 5: SLIs and SLOs — turning "is it broken?" into "how much error budget did that burn?"
— plus a settlement batch job that introduces the third kind of failure: the silent one.
