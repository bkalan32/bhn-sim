# Day 2 — Your First Production Service (and Its First Dashboard)

Adapted from `day2firstserviceanddashboard.pdf`. Every change is justified in
**[CORRECTIONS-DAY2.md](CORRECTIONS-DAY2.md)**.

> **Read this first.** Unlike Day 1, where the problems were just macOS-vs-Windows, Day 2's
> PDF contains real bugs. **The Kubernetes manifest as printed does not parse** — `kubectl
> apply` fails outright. There is also a latency bug that silently drops requests from your
> metrics. Both are fixed in this repo's files. Use these, not the PDF's.

---

## Where Day 1 left you

A cluster, Prometheus and Grafana inside it, Jenkins on the side, a README that rebuilds all
of it. Nothing in the cluster is yours yet.

Today you build the first real piece of the fake business. **This is the most important day
of the series** — everything after it (alerts, incidents, AI summaries) needs a service
producing real signals.

---

## The business flow you're simulating

In a gift card network, activation is the crown-jewel transaction:

1. A cashier scans a gift card at a supermarket
2. The POS calls the network's activation API with card number and amount
3. The network checks the card, checks for fraud, activates it, returns approval
4. The cashier hands the card over — **total budget: well under a second**

Slow API → checkout lines back up in thousands of stores. Errored API → cards sold but never
activated, which is tomorrow's customer service nightmare.

So an incident responder cares about three numbers above all others: **request rate, error
rate, latency.** Today you make those three visible.

---

## Step 1 — Build the service and its image

```bash
cd ~/bhn-sim
./scripts/10-build-activation.sh
```

That one script does Steps 1–3 of the PDF: creates the venv, installs FastAPI + uvicorn +
prometheus-client, pins them into `requirements.lock.txt`, runs a quick in-process test of
`/healthz` `/activate` `/metrics`, builds `activation:0.1`, and loads it into kind.

**Read `services/activation/app.py` before moving on.** It is short and three things matter:

- **The environment variables at the top are your incident controls.** `ERROR_RATE`,
  `BASE_LATENCY_MS`, `FRAUD_SVC_DOWN`. From tomorrow on you turn these to cause outages on
  purpose.
- **A Counter and a Histogram** cover 90% of the metrics you will ever write. Counters only
  go up (requests, errors). Histograms record distributions (latency), which is where p95 and
  p99 come from.
- **`/metrics` is what Prometheus scrapes.** Every service in a modern platform exposes one.

Two things in that file differ from the PDF and are worth understanding:

> **The sleep is floored at zero.** The PDF calls `time.sleep(random.gauss(80, 20)/1000)`.
> A gaussian goes negative past 4σ — about 1 request in 50,000 — and `time.sleep()` then
> raises before any metric is recorded. The request fails and **your dashboard never sees
> it**. Turn `BASE_LATENCY_MS` down to 10 for a drill and 30% of requests do this.

> **`def activate`, not `async def`.** FastAPI runs sync handlers in a threadpool, so the
> blocking `time.sleep()` only blocks its own worker. Make it `async def` and one slow
> request stalls every other request in the process. Real production failure mode, very easy
> mistake.

**Why the image tag matters:** `0.1` is a version. *"What version is running right now"* is
one of the first questions asked on an incident bridge. The service also reports it as a
metric (`activation_build_info`) so the dashboard can answer it too.

---

## Step 2 — Deploy to the cluster

```bash
./scripts/11-deploy-activation.sh
```

Applies `k8s/activation.yaml` and waits for the rollout. Four resources:

| Resource | What it does |
|---|---|
| **Namespace** `payments` | a folder for business services, separate from `monitoring` |
| **Deployment** | two replicas, so one can die and the service stays up |
| **Service** | stable name `activation.payments`, load-balances across pods |
| **ServiceMonitor** | tells Prometheus to scrape `/metrics` every 15s |

> **The `release: kps` label on the ServiceMonitor is the whole ball game.**
> kube-prometheus-stack only scrapes ServiceMonitors carrying its Helm release name. Get it
> wrong and your service is **silently** ignored — no error, no warning, just a target that
> never appears. The PDF is right to call this a classic real-world observability bug, and
> the deploy script checks it for you.

---

## Step 3 — Confirm Prometheus is actually scraping

```bash
./scripts/13-verify-scrape.sh
```

This queries the Prometheus API instead of having you eyeball the Targets page, so it is a
pass/fail check you can re-run any time.

It also **looks the Prometheus service name up** rather than hardcoding it:

```bash
kubectl get svc -n monitoring -l app.kubernetes.io/name=prometheus
```

Names in this chart depend on the Helm release name and a 26-character truncation rule. For
release `kps` it comes out as `kps-kube-prometheus-stack-prometheus` — which is what the PDF
says, and what I got wrong in Day 1's README. Looking it up beats remembering it.

Expect `no data` on the first run. Counters do not exist until something increments them.

---

## Step 4 — Generate traffic

```bash
./scripts/12-loadgen.sh          # ~8 req/s; pass a number to change it
```

Leave this running all day. It is your fake store network.

> ⚠️ **If you still have `uvicorn app:app --port 8000` running from your own experimenting,
> stop it first.** Both want port 8000. If the local one holds it, the port-forward fails to
> bind and your load generator hammers the process on your laptop — which Prometheus does not
> scrape. Traffic flows, terminal looks busy, **dashboard stays empty.** The script refuses to
> start in that situation and tells you.

Output looks like this — if you see `unreachable`, the port-forward died:

```
[14:22:31]   7.8 req/s   200=37  500=1
```

Now re-run `./scripts/13-verify-scrape.sh` in another terminal. You should see both targets
UP and non-zero numbers.

**Note:** `port-forward` against a Service pins **one pod** — it does not load-balance. One
replica gets everything, the other gets nothing. That's expected, and it's why every panel
uses `sum()` across pods.

---

## Step 5 — Build the dashboard

Open Grafana:

```bash
./scripts/06-grafana.sh          # holds the port-forward; http://localhost:3000
```

**Import the ready-made one:** Dashboards → New → Import → upload
`dashboards/activation.json` → pick your Prometheus datasource.

**But build one by hand first, at least once.** You will be doing this under pressure
someday. New dashboard → three panels:

**Panel 1 — Request rate (req/s)**
```promql
sum(rate(activation_requests_total[1m]))
```

**Panel 2 — Error rate (%)**
```promql
100 * sum(rate(activation_requests_total{status="error"}[1m]))
    / clamp_min(sum(rate(activation_requests_total[1m])), 0.001)
```

`clamp_min` is my addition. The PDF divides by a bare `sum(rate(...))`, which is `0` whenever
traffic stops, giving `NaN`. Harmless today — but on Day 5 you build SLO alerts on this
expression, and **an alert rule that evaluates to `NaN` never fires.** Silent alerting gap.

**Panel 3 — p95 latency (seconds)**
```promql
histogram_quantile(0.95, sum(rate(activation_latency_seconds_bucket[1m])) by (le))
```

Set the range to the last 15 minutes. **This is what normal looks like:**

| Signal | Normal |
|---|---|
| Request rate | 5–8 req/s, steady |
| Error rate | ~2% |
| p95 latency | ~0.1s |

Burn those numbers in. Recognising abnormal requires knowing normal.

Save, then export (Dashboard settings → JSON Model) over `dashboards/activation.json` and
commit it. **Dashboards are code too.**

---

## Step 6 — Your first mini-incident

```bash
./scripts/14-mini-incident.sh              # 30% errors for 3 minutes, then recover
```

It raises `ERROR_RATE` to 0.30, holds, prints the measured error rate every 30 seconds, then
rolls back to 0.02 and watches recovery. Do it manually too:

```bash
kubectl set env deployment/activation -n payments ERROR_RATE=0.30
# watch the dashboard climb to 30%
kubectl set env deployment/activation -n payments ERROR_RATE=0.02
```

**Watch Grafana while it happens, not the terminal.** That loop — see it, change something,
confirm recovery on the dashboard — is the core of incident response. Everything else is
process wrapped around it.

Note `set env` rolls the pods, so counters restart from zero. That's fine: `rate()` detects
counter resets and handles them.

Afterwards, write down two numbers: how long until you *noticed*, and how long until you were
*sure* it had recovered. Those are time-to-detect and time-to-verify, and you'll be asked for
them in real postmortems.

---

## Step 7 — Update the runbook

`README.md` already has the Day 2 sections filled in — the build/deploy commands, the three
env vars and what each simulates, the three queries and their normal values. Check it reads
correctly, then:

```bash
git add -A && git commit -m "Day 2: activation service, dashboard, first mini-incident"
git push
```

---

## Day 2 is done when

```bash
./scripts/18-checkpoint-day2.sh
```

- two `activation` pods Ready in namespace `payments`
- the ServiceMonitor exists and both targets are UP in Prometheus
- the load generator is running and the dashboard shows traffic
- you have caused and recovered a 30% error spike and watched it happen
- `dashboards/activation.json` and the README are committed

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl apply` YAML errors | You used the PDF's manifest | Use `k8s/activation.yaml` from this repo |
| Target missing in Prometheus | `release:` label ≠ Helm release name | `kubectl get servicemonitor activation -n payments -o yaml`, fix the label |
| Pods `ErrImagePull` | Forgot `kind load`, or tag mismatch | Re-run `./scripts/10-build-activation.sh` |
| Dashboard flat, loadgen looks fine | Stale local `uvicorn` on :8000 | `kill $(lsof -t -i:8000)`, restart `12-loadgen.sh` |
| Dashboard flat, no loadgen output | Port-forward died silently | Port-forwards drop when a terminal closes. Restart it |
| Metric names not found | Nothing incremented them yet | Send at least one request first |
| `ensurepip is not available` | Missing `python3-venv` | `sudo apt-get install -y python3-venv` |
| One pod busy, one idle | `port-forward` pins one pod | Expected — see Step 4 |
| Error rate reads `NaN` | Zero traffic, divide by zero | Use the `clamp_min` version |

---

## What's next

Day 3 adds structured logging, ships logs to Splunk, and introduces the first real alert rule
with Alertmanager. That is when the pager starts going off.

Two things to line up before you start it:

- **Start the Splunk container on Day 3, not before.** The 60-day Enterprise trial clock
  starts at first run, and the Free licence that follows cannot run alerts at all.
- **Check your ServiceNow PDI.** If you requested it on Day 1 it may have come through; if
  it's still waitlisted, keep going without it.
