# Day 2 — Corrections Log

Source: `day2firstserviceanddashboard.pdf`
Target: Windows + WSL2 Ubuntu, cluster `kind-bhn-sim`
Verified 1 September 2026.

Day 1's problems were platform translation. **Day 2's are real bugs.** Two of them stop
the day dead, and one is a latent fault that will corrupt your metrics later in the series
in a way that is genuinely hard to diagnose.

---

## [BUG] B1 — The Kubernetes manifest does not parse. Day 2 cannot proceed as printed.

This is the blocker. `kubectl apply -f k8s/activation.yaml` fails outright. I ran the PDF's
YAML through a parser to be sure:

```
ParserError: while parsing a block mapping
  expected <block end>, but found '<block sequence start>'
```

Two independent faults:

**1. `readinessProbe` and `resources` are indented wrong.**

```yaml
                    env:                                    # column 20
                        - {name: ERROR_RATE, value: "0.02"} # column 24
                      readinessProbe:                       # column 22  <-- invalid
```

Column 22 is deeper than `env` but shallower than `env`'s list items. It is neither a
sibling of `env` nor a child of anything. YAML rejects it.

**2. Every document separator after the Deployment is indented.**

```yaml
            ---
            apiVersion: v1
            kind: Service
```

An indented `---` is not a document separator — it is content. So the Service and the
ServiceMonitor get swallowed into the Deployment document rather than becoming their own
resources. Even if fault 1 were fixed, you would end up with no Service and no scraping.

**Substitute:** `k8s/activation.yaml` in this repo, rewritten with correct structure and
validated (4 documents: Namespace, Deployment, Service, ServiceMonitor).

---

## [BUG] B2 — `time.sleep()` on a gaussian will crash the service, silently

**Guide, Step 2:**

```python
time.sleep(random.gauss(BASE_LATENCY_MS, 20) / 1000)
```

A gaussian is unbounded below. `gauss(80, 20)` goes negative past 4σ — about **1 request in
50,000** (measured over 200,000 draws). `time.sleep()` with a negative argument raises `ValueError: sleep length must be
non-negative`.

Why this is worse than a rare crash: the exception fires **before** any `REQUESTS.labels()`
or `LATENCY.observe()` call. The request 500s, and **no metric records it.** Your dashboard
shows a perfectly healthy service while real requests fail. That is the exact failure mode
this entire series is teaching you to hunt, shipped accidentally in the example code.

And it gets much worse on purpose. From Day 4 or so you will turn `BASE_LATENCY_MS` down to
compare fast and slow paths. At `BASE_LATENCY_MS=10`, **30.5%** of draws are negative — measured, not estimated
and the service falls apart in a way the metrics do not explain.

**Substitute:**

```python
return max(0.0, random.gauss(BASE_LATENCY_MS, LATENCY_JITTER_MS) / 1000.0)
```

---

## [BUG] B3 — Nothing tells you to stop the local `uvicorn`, and that is why the dashboard stays flat

**Step 2** has you run `uvicorn app:app --port 8000` on your laptop.
**Step 6** has you run `kubectl port-forward svc/activation ... 8000:8000` and point the load
generator at `localhost:8000`.

Both want port 8000. The PDF never says to stop the first one. If it is still running, the
port-forward fails to bind — and your load generator cheerfully hammers the **local** process,
which Prometheus does not scrape. Traffic flows, the terminal looks busy, and the dashboard
is empty.

The PDF's own troubleshooting section lists "Dashboard flat" without connecting it to the
cause it created two steps earlier.

**Substitute:** `scripts/12-loadgen.sh` checks port 8000 is free before starting, names the
stale uvicorn as the likely culprit, and owns both the port-forward and the generator in one
process group so they cannot drift apart.

---

## [BUG] B4 — The load generator hides its own failure

**Guide, Step 6:**

```python
try:
    urllib.request.urlopen(req, timeout=5)
except Exception:
    pass
```

Every failure is swallowed. A dead port-forward, a DNS failure, a crashed pod, and a fully
healthy service all produce identical output: silence. This is the same anti-pattern the
series will later teach you to hunt in production code.

**Substitute:** `tools/loadgen.py` counts responses by status code and prints a rolling
summary every 5 seconds, with an explicit warning when *everything* is unreachable:

```
[14:22:31]   7.8 req/s   200=37  500=1
[14:22:36]   0.0 req/s   unreachable (URLError)=39
  ^ nothing is reaching the service. Is the port-forward still up?
```

---

## [BUG] B5 — The latency histogram has no `status` label

**Guide, Step 2:** `LATENCY = Histogram("activation_latency_seconds", ..., buckets=[...])`

Every observation lands in one undifferentiated bucket set, so you can never ask *"how slow
are the failures specifically?"* — which is one of the first questions worth asking, because
"fast failures" and "slow failures" point at completely different root causes. A fast 500 is
usually logic; a slow 503 is usually a dependency.

**Substitute:** added `["status"]`. Costs nothing, and **all three of the PDF's queries keep
working unchanged** because `sum(...) by (le)` collapses the extra label away.

---

## [BUG] B6 — Error-rate panel goes `NaN` whenever traffic stops

**Guide, Step 7, Panel 2:**

```promql
100 * sum(rate(activation_requests_total{status="error"}[1m]))
    / sum(rate(activation_requests_total[1m]))
```

When the load generator is stopped the denominator is 0, and the panel reads `NaN` / "No
data" rather than a sensible 0%. Minor on Day 2, but on Day 5 you build SLO alerts on this
expression, and an alert rule that evaluates to `NaN` does not fire — a silent alerting gap.

**Substitute:** `clamp_min(sum(rate(activation_requests_total[1m])), 0.001)` in the
denominator, used in `dashboards/activation.json`.

---

## [BUG] B7 — Two replicas, but `port-forward` only ever talks to one

**Step 4** deploys `replicas: 2` and explains "one can die and the service stays up."
**Step 6** then sends all traffic through `kubectl port-forward svc/activation`.

`port-forward` against a Service does **not** load-balance — it resolves the Service to a
single pod and pins it. So one replica takes 100% of the traffic and the other takes none,
and the resilience the step just described is never actually exercised.

Not a fault to fix so much as one to *know*: it explains why per-pod graphs look lopsided,
and it is why every panel in the dashboard uses `sum()` across pods. The script says so at
runtime.

---

## [BUG] B8 — `readinessProbe` on `/healthz` conflates two different questions

The PDF points readiness at `/healthz`, the same endpoint used for liveness. They answer
different questions: liveness is *"is this process alive?"*, readiness is *"should it get
traffic?"* Sharing one endpoint means you can never drain a pod without Kubernetes also
killing it.

There is a concrete consequence coming. When you set `FRAUD_SVC_DOWN=true` (Day 4+), every
request hangs 3 seconds. With a default liveness probe (1s timeout, 3 failures) Kubernetes
decides the pod is dead and restarts it — your controlled latency drill turns into
`CrashLoopBackOff`, and the symptom you were trying to observe disappears behind restarts.

**Substitute:** separate `/healthz` and `/readyz`, plus a deliberately generous liveness
probe (`timeoutSeconds: 5`, `failureThreshold: 6`) so latency drills stay observable.

---

## [PLATFORM] P1 — `python3 -m venv` needs a package Ubuntu does not ship by default

`python3 -m venv .venv` fails on a clean Ubuntu with *"ensurepip is not available"*. Day 1's
`01-install-tools.sh` already installs `python3-venv`, so you are covered — but if you built
Day 1 by hand from the PDF, run `sudo apt-get install -y python3-venv` first.

---

## ⚠️ Found live — my own bug

**The NodePort Service I added carried `app: activation` in `metadata.labels`**, which is
what the ServiceMonitor selects on. Prometheus discovered both Services, scraped every pod
twice, and `sum(rate(...))` doubled every number on the dashboard — 8.8 req/s reported
against 4.5 real. It surfaced as a plausible, wrong number; the tell was duplicate rows in
the target list and the proof was the load generator's own count. `metadata.labels` (what
selectors find) and `spec.selector` (which pods this routes to) are different things.
Fixed: the NodePort is labelled `role: front-door`.

## ⚠️ Correction to my own Day 1 notes

In the Day 1 README I gave the Prometheus service as `kps-kube-prometheus-prometheus`.
**That was wrong, and the PDF is right.** I traced the chart's `_helpers.tpl`:

```
fullname = printf "%s-%s" .Release.Name "kube-prometheus-stack" | trunc 26
```

`kps-kube-prometheus-stack` is 25 characters, so it survives truncation intact, and the
service is **`kps-kube-prometheus-stack-prometheus`** — exactly what the PDF says. The name
I remembered (`prometheus-kube-prometheus-prometheus`) is what you get from a release named
`prometheus`, where truncation *does* bite. My mistake; Day 1's README is now fixed.

The lesson is the useful part, so the scripts no longer hardcode it at all:

```bash
kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus
```

Look it up, don't memorise it.

---

## Verified as correct — no change needed

- **`kind load docker-image activation:0.1 --name bhn-sim`** — correct, and the explanation
  of why it is needed is right.
- **`release: kps` on the ServiceMonitor** — correct, and the PDF is right that omitting it
  is a *silent* failure. This is the single most valuable warning in the day.
- **`kubectl port-forward svc/kps-kube-prometheus-stack-prometheus`** — correct for a release
  named `kps`. See above; I was the one who was wrong.
- **All three golden-signal PromQL queries** — correct, and they still work against the
  modified metrics.
- **`imagePullPolicy: IfNotPresent`** — necessary with `kind load`; without it the kubelet
  tries to pull `activation:0.1` from Docker Hub and fails.
- **`def activate` rather than `async def`** — correct and important. FastAPI runs sync
  handlers in a threadpool, so the blocking `time.sleep()` only blocks its own worker. Change
  it to `async def` and one slow request stalls every other request in the process.
- **The framing of Step 8** — see it, change something, confirm recovery. That loop really is
  the core of the job.
