"""
settlement — the nightly reconciliation job.

Every night a gift card network reconciles the day's activations against what the
retailers report, computes what each party owes, and prepares the money movement. If
this does not run, nobody gets paid and finance notices days later.

It has no request rate, no latency, no 500s. It either ran correctly or it did not — and
"did not" can be COMPLETELY SILENT. That is the failure mode this job exists to teach.

    SETTLEMENT_FAIL_MODE   none | crash | silent
    SETTLEMENT_STRICT      "true" -> refuse to report success on zero records
                           (the real fix; off by default so you can SEE the silent
                           failure first, then turn it on for INC-0005's follow-up)
    PUSHGATEWAY            host:port of the Pushgateway
"""

import datetime as _dt
import json
import os
import random
import sys
import time

from prometheus_client import CollectorRegistry, Gauge, push_to_gateway

FAIL_MODE = os.getenv("SETTLEMENT_FAIL_MODE", "none").strip().lower()
STRICT = os.getenv("SETTLEMENT_STRICT", "false").strip().lower() == "true"
GATEWAY = os.getenv("PUSHGATEWAY", "pushgateway-prometheus-pushgateway.monitoring:9091")
VERSION = os.getenv("APP_VERSION", "0.1")


def log(level, msg, **fields):
    rec = {
        "ts": _dt.datetime.now(tz=_dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "level": level, "service": "settlement", "version": VERSION, "msg": msg, **fields,
    }
    print(json.dumps(rec, separators=(",", ":")), flush=True)


reg = CollectorRegistry()
processed = Gauge("settlement_records_processed", "Records reconciled in last run", registry=reg)
mismatches = Gauge("settlement_mismatches", "Records that did not reconcile", registry=reg)
last_success = Gauge("settlement_last_success_timestamp", "Unix time of last SUCCESSFUL run", registry=reg)
# ADDED vs the PDF: two more gauges so alerts can tell "did not run" apart from "ran and
# failed" from "ran and lied". The PDF's single last_success timestamp cannot.
last_run = Gauge("settlement_last_run_timestamp", "Unix time of last run, success or not", registry=reg)
last_status = Gauge("settlement_last_run_status", "1 = success, 0 = failure", registry=reg)
duration = Gauge("settlement_duration_seconds", "Run duration", registry=reg)


def push(ok: bool):
    """Push whatever we have. Never let a push failure mask the job's own outcome."""
    last_run.set(time.time())
    last_status.set(1 if ok else 0)
    try:
        push_to_gateway(GATEWAY, job="settlement", registry=reg)
    except Exception as e:  # noqa: BLE001
        log("ERROR", "metrics push failed", error=type(e).__name__, gateway=GATEWAY)


start = time.time()
log("INFO", "settlement starting", fail_mode=FAIL_MODE, strict=STRICT)

if FAIL_MODE == "crash":
    # Loud. Kubernetes sees exit 1 -> Job Failed -> kube_job_status_failed=1.
    log("ERROR", "database connection refused", reason="db_unreachable")
    duration.set(time.time() - start)
    push(ok=False)
    sys.exit(1)

records = 0 if FAIL_MODE == "silent" else random.randint(4000, 6000)
time.sleep(random.uniform(5, 15))
bad = 0 if records == 0 else random.randint(0, 3)

processed.set(records)
mismatches.set(bad)
duration.set(time.time() - start)

if records == 0 and STRICT:
    # The real fix. A settlement that reconciles nothing is not a success, and the
    # job should be the first thing to say so — not an alert, and not finance.
    log("ERROR", "settlement produced zero records — refusing to report success",
        records=0, reason="zero_records")
    push(ok=False)
    sys.exit(2)

if records > 0:
    last_success.set(time.time())

# Look at the silent mode from the outside: exit 0, "settlement complete", metrics
# pushed, Kubernetes says Succeeded. Nothing is red anywhere. Records: 0.
log("INFO", "settlement complete", records=records, mismatches=bad,
    duration_s=round(time.time() - start, 1))
push(ok=True)
