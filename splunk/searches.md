# Incident search library

The three questions an incident responder asks, in order. Save each as a Report in
Splunk — this is the beginning of a library you will keep adding to for the rest of the
series.

> Fields arrive as `app.<field>` because Fluent Bit merges the container's JSON under
> the key `app` (`Merge_Log_Key app`). That keeps your application fields from
> colliding with Kubernetes metadata like `kubernetes.pod_name`.

**Why is it failing?**
```spl
index=main app.service=activation app.status=error | stats count by app.reason
```

**When did it start, and is it getting worse?**
```spl
index=main app.service=activation | timechart span=1m count by app.status
```

**Where is it failing?**
```spl
index=main app.service=activation app.status=error | top app.store_id
```

**During an active incident — last 5 minutes only:**
```spl
index=main app.service=activation app.status=error earliest=-5m | stats count by app.reason
```

**Slowest requests, to separate "slow" from "broken":**
```spl
index=main app.service=activation | stats avg(app.latency_ms) p95(app.latency_ms) max(app.latency_ms) by app.status
```

**Sanity check that logs are arriving at all** — run this first when a search returns
nothing, before assuming the service is fine:
```spl
index=main | stats count by sourcetype, host
```

**Check your licence burn** (you have 500 MB/day on trial *and* free):
```spl
index=_internal source=*license_usage.log type=Usage | timechart span=1h sum(b) as bytes
```
