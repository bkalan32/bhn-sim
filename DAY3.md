# Day 3 — Logs, Splunk, and the First Alert

Adapted from `day3logssplunkfirstalert.pdf`. Every change is justified in
**[CORRECTIONS-DAY3.md](CORRECTIONS-DAY3.md)**.

> **Before you start.** The PDF's `k8s/alerts.yaml` does not parse, so no alerts load —
> including the one the whole day is built around. And the Splunk Enterprise Trial indexes
> **500 MB/day, exactly the same as Free** — the trial buys alerting and 60 days, not
> volume. The PDF's Fluent Bit config ships your entire cluster and will burn that quota in
> about a day. Both are fixed here.

---

## Where Day 2 left you

Two replicas serving traffic, Prometheus scraping, a Grafana dashboard, and an error spike
you caused and recovered by hand.

Two things were missing. **Nobody told you** when the error rate spiked — you were staring
at the dashboard. And the dashboard told you errors *happened*, not *why*.

Metrics answer "is something wrong?" Logs answer "what exactly went wrong?" Today you get
both, plus the pager.

---

## The sequence you're building

On a real incident bridge it is almost always:

1. An alert fires — **metrics**
2. Someone opens the dashboard to see the shape — **metrics**
3. Someone searches logs for the error, the store, the failing dependency — **logs**
4. Someone forms a theory and acts

Steps 1 and 3 are today's work.

---

## Step 1 — Ship v0.2 with structured logging

```bash
cd ~/bhn-sim
./scripts/20-upgrade-activation.sh
```

Builds `activation:0.2`, loads it into kind, applies the manifest, and prints a few parsed
log lines.

**Read the logging block in `services/activation/app.py` first.** Two things:

**Why JSON.** A line that is one JSON object per line can be searched *by field*. "Show me
all errors from STORE-0421 with reason `fraud_service_timeout`" is a five-second query.
The same question against free-text logs is a regex nightmare at 3 AM.

**Why only the last four digits.** Never log a full card number. In a payments company that
is a compliance violation, not a style choice. There's an assertion in the test that fails
if a full PAN ever reaches a log line.

Two differences from the PDF worth knowing:

> **Timestamps are UTC with a `Z`.** The PDF uses `%Y-%m-%dT%H:%M:%S` in *local* time with
> no timezone marker. Prometheus, Grafana and Kubernetes events are all UTC. Mid-incident
> you'd be doing timezone math in your head — and getting it wrong.

> **The manifest is bumped to 0.2, not `kubectl set image`.** The PDF's approach leaves
> `k8s/activation.yaml` saying `0.1`, so the next `kubectl apply` **silently downgrades you
> and deletes your logging.** No error. Your Splunk searches just stop returning new events.

---

## Step 2 — Start Splunk

```bash
./scripts/21-splunk-up.sh
```

> ⚠️ **This starts the 60-day trial clock.** Which is exactly why Day 1 said not to.

Takes 2–4 minutes. Then **http://localhost:8000**, `admin` / `Changeme123!`.

**Create the HEC token by hand** — this part can't be scripted:

1. Settings → Data Inputs → HTTP Event Collector → **New Token**
2. Name it `k8s`, accept defaults, **copy the token value** at the end
3. On the same page: **Global Settings → All Tokens → Enabled**

Step 3 is the one everyone forgets. A token that exists but is globally disabled returns
403, and Fluent Bit logs that once, quietly.

---

## Step 3 — Ship logs with Fluent Bit

```bash
./scripts/22-fluent-bit.sh <YOUR-TOKEN>
```

Before installing anything, it **sends a real test event to HEC** and translates the answer:
403 = bad token or All Tokens off, 400 = index problem, no response = HEC off or Splunk
still booting. The PDF installs the whole pipeline first and leaves you guessing.

It also renders the Splunk IP live with `docker inspect` instead of hardcoding it. Docker
reassigns container IPs on restart, and a stale IP presents as "no data in Splunk" with
nothing anywhere explaining why.

What the pieces do:

- **tail input** reads container logs on the node — **payments namespace only**, see below
- **kubernetes filter** attaches pod, namespace and labels, and `Merge_Log On` parses your
  JSON so fields become searchable
- **splunk output** pushes to HEC on 8088

> **Why only the payments namespace.** The PDF tails `/var/log/containers/*.log` — the whole
> kube-prometheus-stack, CoreDNS, the control plane, and Fluent Bit's own pod logging about
> shipping logs. At 500 MB/day you'll blow the quota in about a day, and **five violations in
> a rolling 30-day window disables search.** None of that volume answers a single question
> in Step 4.

---

## Step 4 — Search your logs

**http://localhost:8000** → Search:

```spl
index=main app.service=activation
```

Give it 60 seconds. Then work through **`splunk/searches.md`** — the three questions an
incident responder actually asks:

| Question | Search |
|---|---|
| **Why** is it failing? | `... app.status=error \| stats count by app.reason` |
| **When** did it start? | `... \| timechart span=1m count by app.status` |
| **Where** is it failing? | `... app.status=error \| top app.store_id` |

Save all three as Reports. This is the start of your incident search library, and you'll add
to it every day for the rest of the series.

Fields arrive as `app.<field>` because of `Merge_Log_Key app`, which keeps your application
fields from colliding with Kubernetes metadata like `kubernetes.pod_name`.

---

## Step 5 — The first alert rules

```bash
./scripts/23-alerts.sh
```

Applies the rules and then **proves Prometheus actually loaded them** by querying the API —
the PDF has you eyeball the Alerts page.

**Read the design, because alert design is a named responsibility in the job:**

- **`> 10`, not `> 0`.** The service has a 2% baseline. Alerting on any error pages you
  constantly. That's alert fatigue, and reducing it is explicitly part of the role.
- **`for: 2m`.** The condition must *hold*. A ten-second blip doesn't wake anyone.
- **critical vs warning.** Errors mean cards aren't selling — critical. Slow but working —
  warning.
- **The annotation is what a human reads at 3 AM.** Ours names the business impact and
  includes the next query to run.

Two fixes beyond the PDF:

> **`clamp_min` on the denominator.** The PDF's expression divides by a bare `sum(rate(...))`.
> Zero traffic → `NaN` → `NaN > 10` is false → **the alert never fires and never goes
> pending.** It looks identical to a healthy service. Your Day 2 port-forward outage would
> have been completely silent under these rules.

> **A third alert: `ActivationNoTraffic`.** If traffic stops, every ratio-based rule goes
> quiet — not because things are healthy, but because there's nothing to measure. "No data"
> has to be its own alert or it's a blind spot.

---

## Step 6 — Watch it fire

Have four things open: **Grafana** (3000), **Prometheus Alerts** (9090/alerts),
**Alertmanager** (9093), **Splunk** (8000).

```bash
kubectl port-forward svc/kps-kube-prometheus-stack-alertmanager -n monitoring 9093:9093
```

Then, in terminal #1:

```bash
./scripts/24-incident-fraud.sh
```

It waits for you before injecting, prints error rate / p95 / alert state every 30 seconds,
and waits again before recovering. Over about four minutes:

1. **Grafana** — error rate to 100%, p95 past 3 seconds
2. **Prometheus** — `ActivationHighErrorRate` goes yellow (Pending) then red (Firing);
   `ActivationHighLatency` follows
3. **Alertmanager** — both appear with labels and annotations
4. **Splunk** —
   ```spl
   index=main app.service=activation app.status=error earliest=-5m | stats count by app.reason
   ```
   → **`fraud_service_timeout`**

**That fourth step is the point of the entire day.** The alert said *errors*. The dashboard
said *everything, and slow*. Only the logs named the dependency. Three layers, three
different questions, one narrowing.

Traffic keeps flowing through the NodePort during the rollout — that's why we stopped using
a port-forward for load on Day 2.

---

## Step 7 — Write it up

`incidents/INC-0001.md` is scaffolded. Fill in your timestamps and your own answers,
especially:

> **Should activation fail fast when fraud is down, instead of waiting 3 seconds for a
> result it will never get?**

That bullet is the difference between fixing an incident and engineering it away — and it's
exactly what the job description means by "engineer permanent solutions rather than
repeatedly fixing the same thing."

```bash
git add -A && git commit -m "Day 3: JSON logs, Splunk, first alerts, INC-0001"
git push
```

Note `k8s/fluent-bit-values.yaml` is gitignored — it holds your HEC token.

---

## Day 3 is done when

```bash
./scripts/28-checkpoint-day3.sh
```

- service on v0.2 emitting JSON logs
- Splunk shows activation events with searchable fields
- all three alert rules loaded in Prometheus
- you made `ActivationHighErrorRate` fire *and* resolve, and saw it in Alertmanager
- `INC-0001.md`, alert rules, Fluent Bit template and README committed

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl apply` YAML error on alerts | You used the PDF's file | Use `k8s/alerts.yaml` from this repo |
| No data in Splunk | Bad token | `kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit` — 403 = token or All Tokens disabled |
| No data in Splunk | Stale IP | Re-run `22-fluent-bit.sh` — it re-reads the live IP |
| No data, no errors | Token's index isn't `main` | Check the token's Allowed Indexes |
| Fields are `status` not `app.status` | `Merge_Log_Key` changed | Expected is `app.` — that's the setting |
| Alert never fires | Missing `release: kps` | Same rule as the ServiceMonitor |
| Alert never fires | No traffic | `rate()` of nothing is nothing. Check terminal #2 |
| Licence violation banner | Ingesting too much | Confirm the Path is `*_payments_*.log`, not `*.log` |
| Splunk eats all the RAM | It wants ~2 GB | `docker stop jenkins` for today |
| Pods evicted after starting Splunk | WSL memory | Raise `memory=` in `.wslconfig`, `wsl --shutdown` |

---

## What's next

Day 4 adds distributed tracing with OpenTelemetry and a second service (eGift issuance) that
calls this one — so you can watch a request cross a service boundary and find which hop is
slow. That's the question neither metrics nor logs answer well on their own.
