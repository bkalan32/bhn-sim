# Day 3 — Corrections Log

Source: `day3logssplunkfirstalert.pdf`
Verified 1 September 2026.

Day 1 was platform translation. Day 2 had broken YAML. **Day 3 has broken YAML again, plus
a licensing assumption that will silently cost you your Splunk instance.**

---

## [BUG] B1 — `k8s/alerts.yaml` does not parse

Same class of fault as Day 2's manifest. Under `ActivationHighLatency`, the `expr:` block is
indented to column 23 while `for:`, `labels:` and `annotations:` sit at column 21 — deeper
than the key they belong to, shallower than the block scalar above them. Verified:

```
ParserError: while parsing a block mapping
  expected <block end>, but found '<scalar>'
```

`kubectl apply -f k8s/alerts.yaml` fails, so **no alerts load at all** — including the one
the day is built around. Fixed file is in this repo.

---

## [BUG] B2 — The Enterprise Trial is **also** 500 MB/day

The PDF (Day 1, Step 9) frames it as "60-day Enterprise trial, after which it drops to the
Free license at 500 MB/day," which reads as *trial = roomy, free = constrained*. That is
wrong in the way that matters.

Per Splunk's own docs: the Enterprise Trial indexes **500 MB/day** and the Free licence
indexes **500 MB/day**. Identical volume. What the trial actually buys you is **alerting**,
authentication, distributed search — and 60 days.

**Why this bites:** exceed the quota and you get a licence violation. Accumulate five in a
rolling 30-day window and **search is disabled** until it ages out. Not a warning banner —
your Splunk stops being useful mid-series.

Combined with B3 below, the PDF's configuration will do exactly that.

---

## [BUG] B3 — Fluent Bit ships the entire cluster

**Guide, Step 4:** `Path /var/log/containers/*.log`

That is every container on the node: the full kube-prometheus-stack, CoreDNS, kube-proxy,
the Kubernetes control plane, Jenkins if you moved it in — and Fluent Bit's own pod, which
means Fluent Bit logging about shipping logs, shipped as logs.

With a 500 MB/day ceiling and a load generator running all day, you will blow the quota in
roughly a day. And none of that volume answers a single question in Step 5, which only ever
searches `app.service=activation`.

**Substitute:** `Path /var/log/containers/*_payments_*.log` — the payments namespace only.
Same searches, a small fraction of the ingest. Widen it deliberately later if you need to.

---

## [BUG] B4 — The hardcoded Splunk IP goes stale on the first restart

**Guide, Step 4:** paste `172.18.0.5` into the values file.

Docker reassigns container IPs on restart. Reboot your laptop, restart Docker Desktop, or
recreate the Splunk container, and that file now points at nothing. The symptom is **"no
data in Splunk"** with nothing anywhere that says why — Fluent Bit retries quietly.

**Substitute:** `k8s/fluent-bit-values.yaml.tmpl` is a template; `scripts/22-fluent-bit.sh`
reads the live IP with `docker inspect` and renders it every run. The rendered file holds
your HEC token, so it is gitignored.

The script also **preflights HEC with a real test event before installing anything**, and
translates the response: 403 means bad token or All Tokens disabled, 400 means the index is
wrong, no response means HEC is off or Splunk is still booting. The PDF has you install the
whole pipeline first and then guess.

---

## [BUG] B5 — uvicorn's access log doubles your ingest for nothing

Not in the PDF at all, but it follows directly from B2. uvicorn writes its own plain-text
access line for every request:

```
INFO:     10.244.0.1:52344 - "POST /activate HTTP/1.1" 200 OK
```

That is roughly one non-JSON line per JSON line — about double the volume, unparseable by
the `Merge_Log` filter, and strictly less informative than the structured line the app
already emits. Under a 500 MB/day cap that is half your budget spent on noise.

**Substitute:** `--no-access-log` in the Dockerfile CMD.

---

## [BUG] B6 — `kubectl set image` creates config drift

**Guide, Step 1:** upgrade to 0.2 with `kubectl set image deployment/activation ...`

The command works. The problem is that `k8s/activation.yaml` still says `activation:0.1`,
so the cluster and the repo now disagree. The next time anyone runs `kubectl apply -f
k8s/activation.yaml` — which the PDF's own Day 2 instructions tell you to do — the
deployment **silently rolls back to 0.1** and you lose structured logging. No error. Your
Splunk searches just quietly stop returning new events.

**Substitute:** bump the image in `k8s/activation.yaml` and `apply` it. The manifest stays
the source of truth. `scripts/20-upgrade-activation.sh` refuses to run if the file still
pins an old tag.

---

## [BUG] B7 — The alert expression can never fire when it matters most

**Guide, Step 6:**

```promql
100 * sum(rate(activation_requests_total{status="error"}[2m]))
    / sum(rate(activation_requests_total[2m])) > 10
```

Zero traffic makes the denominator 0, the expression `NaN`, and `NaN > 10` false. The rule
does not fire and does not go pending — it looks exactly like a healthy service.

You already met this failure mode on Day 2, when the port-forward died and your load
generator went to 100% unreachable. Under these rules, that outage would have been
completely silent.

**Substitute:** `clamp_min(..., 0.001)` in the denominator, **plus a new rule the PDF does
not have**:

```yaml
- alert: ActivationNoTraffic
  expr: sum(rate(activation_requests_total[5m])) < 0.1
  for: 5m
```

"No data" has to be its own alert or it is a blind spot. Every ratio-based alert in your
stack shares this hole.

---

## [BUG] B8 — Day 3's code sample reintroduces the Day 2 bugs

The PDF's rewritten `activate()` goes back to:

- `time.sleep(random.gauss(BASE_LATENCY_MS, 20) / 1000)` — the unbounded-negative crash
  (Day 2, B2), which drops requests from your metrics entirely
- `LATENCY.observe(...)` without a status label — which would also break against the
  histogram this repo already deployed

Applying Day 3's snippet verbatim on top of a corrected Day 2 **undoes both fixes**. The
`app.py` in this repo merges the new logging into the corrected code rather than replacing
it.

---

## [BUG] B9 — Timestamps are local time with no timezone

**Guide, Step 1:** `self.formatTime(record, "%Y-%m-%dT%H:%M:%S")`

No timezone marker, and `formatTime` defaults to local time. Prometheus, Grafana and
Kubernetes events are all UTC. At 3 AM, mid-incident, you will be doing timezone arithmetic
in your head to line a log line up against a graph — and you will get it wrong.

**Substitute:** UTC, ISO 8601, explicit `Z`, with milliseconds:
`2026-09-01T22:13:20.347Z`

---

## [PLATFORM] P1 — Port 8000 collides, and the PDF's fix is now unnecessary

The PDF notes that Splunk's web UI on 8000 collides with Day 2's `kubectl port-forward
svc/activation 8000:8000`, and tells you to switch to 8001 and edit `loadgen.py`.

Our Day 2 already moved traffic to a **NodePort on 30080** (because port-forward does not
survive a rolling restart), so there is no collision and nothing to edit. `21-splunk-up.sh`
still checks that 8000 is free and names the likely holder if not.

---

## [PLATFORM] P2 — `splunk/splunk:latest` contradicts the series' own lesson

Day 2 makes the point that the image tag *is* a version and "what is running right now" is
the first question on an incident bridge. Day 3 then pulls `splunk/splunk:latest`, which
means a rebuild in three months silently gives you a different Splunk.

**Substitute:** pinned to `splunk/splunk:9.4`, with a `--memory 3g` cap so a Splunk that
decides to use everything cannot evict your monitoring pods.

---

## Found live, on the machine — three more

**[BUG] B10 — `Merge_Log` never fires: the cri parser writes `message`, the filter reads `log`.**
The kubernetes filter's `Merge_Log On` only inspects a field named `log`. The `cri` parser
stores the container line in `message`. Names don't match, so the JSON arrives in Splunk as
an unparsed string and every `app.*` search returns nothing — while Fluent Bit reports
0 errors and Splunk shows thousands of events. Fixed with a `modify` filter that renames
`message → log` before the kubernetes filter.

**[BUG] B11 — Events land as sourcetype `httpevent`, which Splunk never parses.**
Even with B10 fixed, HEC stamps events `httpevent` by default and Splunk treats that as
opaque text. Fixed with `event_sourcetype _json` on the Fluent Bit output.

**[BUG] B12 — HEC defaults to SSL on in the container; the PDF says `TLS Off`.**
`http://` to 8088 gets no response at all (curl `000`), which looks like "HEC isn't
running." `22-fluent-bit.sh` now probes both schemes and renders `TLS On/Off` to match.

Three silent failures in one pipeline, each reporting healthy. The diagnostic that found
them all: `index=* | stats count by sourcetype` first, then `| head 1` and *read the raw event*.

## Verified as correct — no change needed

- **The incident-response framing.** Alert → dashboard → logs → theory. That really is the
  sequence, and Step 7's three-screen exercise is the best thing in the day.
- **Alert design rationale.** `> 10` not `> 0` because of the 2% baseline; `for: 2m` so a
  blip does not page anyone; critical vs warning split on "cards not selling" vs "slow but
  working." All correct, and worth internalising.
- **`Parser cri`** — correct. kind runs containerd, whose log format is CRI, not Docker JSON.
- **`Merge_Log_Key app`** — correct, and the reason it gives (keeping your fields away from
  Kubernetes metadata) is right. That is why searches use `app.status`, not `status`.
- **Never logging full card numbers.** Correct, and correctly framed as compliance rather
  than style. Verified by assertion in this repo's tests: only `card_last4` is ever emitted.
- **`kps-kube-prometheus-stack-alertmanager`** — correct for a release named `kps`.
- **The Step 8 follow-up question** ("should activation fail fast when fraud is down?") is
  the most valuable line in the whole document.
