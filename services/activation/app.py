"""
activation — the card activation service.

The crown-jewel transaction: a cashier scans a gift card, the POS calls this API,
and a card must be activated in well under a second. Slow here means checkout lines
back up in thousands of stores. Errors here mean cards sold but never activated.

Three environment variables are your incident controls. You will turn them on purpose
from Day 2 onward to cause outages:

    ERROR_RATE        fraction of requests that fail outright   (default 0.02)
    BASE_LATENCY_MS   mean simulated work time in ms            (default 80)
    FRAUD_SVC_DOWN    "true" makes the fraud dependency hang    (default false)

v0.2 (Day 3) adds structured JSON logging. Metrics answer "is something wrong?";
logs answer "what exactly went wrong?"
v0.3 (Day 4) adds the trace ID to every log line. Traces answer "WHERE in the chain
did the time go?" -- and the trace ID is the key that joins all three together.

Differences from the version printed in the PDF are marked FIX: and explained in
CORRECTIONS-DAY2.md and CORRECTIONS-DAY3.md.
"""

import datetime as _dt
import json
import logging
import os
import random
import sys
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel

# Day 4: the process is started under `opentelemetry-instrument`, which auto-wraps
# FastAPI and outgoing HTTP. This import only reads the *current* span so the log line
# can carry its trace ID. If the wrapper is absent (e.g. running tests locally), the
# span is a no-op and trace_id is simply omitted -- nothing breaks.
from opentelemetry import trace

VERSION = os.getenv("APP_VERSION", "0.3")

app = FastAPI(title="activation", version=VERSION)

# --------------------------------------------------------------- logging ----
class JsonFormatter(logging.Formatter):
    """One JSON object per line.

    Why JSON: "show me all errors from STORE-0421 with reason fraud_service_timeout"
    is a five-second field query. The same question against free-text logs is a regex
    nightmare at 3 AM.

    FIX: the PDF formats the timestamp with "%Y-%m-%dT%H:%M:%S" in LOCAL time and no
    timezone marker. Correlating those against Prometheus (which is UTC) means doing
    timezone arithmetic in your head during an incident. This emits UTC with a Z.
    """

    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": _dt.datetime.fromtimestamp(
                record.created, tz=_dt.timezone.utc
            ).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname,
            "service": "activation",
            "version": VERSION,
            "msg": record.getMessage(),
        }
        extra = getattr(record, "extra", None)
        if isinstance(extra, dict):
            payload.update(extra)
        # Log <-> trace correlation. Search Splunk for app.trace_id=<id> and you get
        # every service's log lines for one request, together. In a real company that
        # join is worth a lot of money in reduced diagnosis time.
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter())
log = logging.getLogger("activation")
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
log.addHandler(_handler)
log.propagate = False


# ---------------------------------------------------------------- knobs -----
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.02"))
BASE_LATENCY_MS = float(os.getenv("BASE_LATENCY_MS", "80"))
LATENCY_JITTER_MS = float(os.getenv("LATENCY_JITTER_MS", "20"))
FRAUD_SVC_DOWN = os.getenv("FRAUD_SVC_DOWN", "false").strip().lower() == "true"
FRAUD_TIMEOUT_S = float(os.getenv("FRAUD_TIMEOUT_S", "3"))

# --------------------------------------------------------------- metrics ----
# Counters only go up (requests, errors). Histograms record distributions
# (latency), which is how you get p95 and p99. These two cover 90% of the
# metrics you will ever write.
REQUESTS = Counter(
    "activation_requests_total", "Activation requests", ["status"]
)
# FIX: the PDF's histogram has no labels, so you can never ask "how slow are the
# FAILURES specifically?" — the question you actually ask at 3 AM. Adding the
# status label costs nothing and keeps every query in the PDF working, because
# `sum(...) by (le)` collapses it away.
LATENCY = Histogram(
    "activation_latency_seconds",
    "Activation latency",
    ["status"],
    buckets=[0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5],
)
# "What version is running right now?" is one of the first questions on an
# incident bridge. Make the service answer it itself.
BUILD_INFO = Gauge("activation_build_info", "Build metadata", ["version"])
BUILD_INFO.labels(version=VERSION).set(1)

IN_FLIGHT = Gauge("activation_in_flight_requests", "Requests currently being served")


class ActivateRequest(BaseModel):
    card_number: str
    amount: float
    store_id: str


def _simulated_work_seconds() -> float:
    """Mean BASE_LATENCY_MS with jitter, floored at zero.

    FIX: the PDF calls time.sleep(random.gauss(80, 20) / 1000) directly. A gaussian
    is unbounded below, so roughly one request in 50,000 draws a negative number (measured) and
    time.sleep() raises ValueError: sleep length must be non-negative. That request
    500s WITHOUT incrementing any counter, so your dashboard shows a healthy service
    while requests fail. It gets much worse the moment you turn BASE_LATENCY_MS down
    during an incident drill — at 10ms, 30.5% of draws go negative and the service
    collapses in a way the metrics do not explain.
    """
    return max(0.0, random.gauss(BASE_LATENCY_MS, LATENCY_JITTER_MS) / 1000.0)


@app.get("/healthz")
def healthz():
    """Liveness: is the process alive at all?"""
    return {"status": "ok", "version": VERSION}


@app.get("/readyz")
def readyz():
    """Readiness: should this pod receive traffic?

    Deliberately separate from /healthz. Later in the series you will want to pull a
    pod out of the load balancer without having Kubernetes kill and restart it, and
    that is impossible if both probes hit the same endpoint.
    """
    return {"status": "ready", "version": VERSION}


# NOTE: this is `def`, not `async def`, on purpose. FastAPI runs sync handlers in a
# threadpool, so the blocking time.sleep() below only blocks its own worker thread.
# Change it to `async def` and the sleep blocks the whole event loop — one slow
# request stalls every other request in the process. That is a real production
# failure mode and a very easy mistake to make.
@app.post("/activate")
def activate(req: ActivateRequest):
    start = time.perf_counter()
    IN_FLIGHT.inc()
    # Only the last four digits. Never log a full card number — in a payments company
    # that is a compliance violation, not a style preference.
    fields = {
        "card_last4": req.card_number[-4:],
        "amount": req.amount,
        "store_id": req.store_id,
    }
    try:
        time.sleep(_simulated_work_seconds())

        if FRAUD_SVC_DOWN:
            time.sleep(FRAUD_TIMEOUT_S)  # fraud service timeout
            elapsed = time.perf_counter() - start
            fields.update(status="error", reason="fraud_service_timeout",
                          latency_ms=round(elapsed * 1000))
            log.error("activation failed", extra={"extra": fields})
            REQUESTS.labels(status="error").inc()
            LATENCY.labels(status="error").observe(elapsed)
            return PlainTextResponse("fraud service unavailable", status_code=503)

        if random.random() < ERROR_RATE:
            elapsed = time.perf_counter() - start
            fields.update(status="error", reason="issuer_declined",
                          latency_ms=round(elapsed * 1000))
            log.error("activation failed", extra={"extra": fields})
            REQUESTS.labels(status="error").inc()
            LATENCY.labels(status="error").observe(elapsed)
            return PlainTextResponse("activation failed", status_code=500)

        elapsed = time.perf_counter() - start
        fields.update(status="ok", latency_ms=round(elapsed * 1000))
        log.info("activation approved", extra={"extra": fields})
        REQUESTS.labels(status="ok").inc()
        LATENCY.labels(status="ok").observe(elapsed)
        return JSONResponse({"approved": True, **fields, "version": VERSION})
    finally:
        IN_FLIGHT.dec()


@app.get("/metrics")
def metrics():
    """The endpoint Prometheus scrapes. Every service in a modern platform has one."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
