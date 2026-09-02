"""
egift — eGift issuance.

A corporate customer orders digital gift cards for their sales team. For each card:
    1. generate a code
    2. activate it            (calls the Day 2 activation service)
    3. deliver it by email    (mocked)

When a customer says "my eGift orders take 30 seconds", the question on the bridge is:
is it code generation, activation, or email? This service is deliberately built so that
tracing answers that in one screen.

Knobs:
    DELIVERY_DELAY_MS   mean email delivery time in ms       (default 40)
    EMAIL_FAIL_RATE     fraction of deliveries that fail     (default 0.01)
    ACTIVATION_URL      where activation lives
    ACTIVATION_TIMEOUT_S  how long we wait on activation     (default 5)

Differences from the PDF are marked FIX: -- see CORRECTIONS-DAY4.md.
"""

import datetime as _dt
import json
import logging
import os
import random
import sys
import time
import uuid

import requests
from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse, Response
from opentelemetry import trace
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel

VERSION = os.getenv("APP_VERSION", "0.1")
app = FastAPI(title="egift", version=VERSION)
tracer = trace.get_tracer("egift")

# ---------------------------------------------------------------- knobs -----
ACTIVATION_URL = os.getenv("ACTIVATION_URL", "http://activation.payments:8000/activate")
ACTIVATION_TIMEOUT_S = float(os.getenv("ACTIVATION_TIMEOUT_S", "5"))
DELIVERY_DELAY_MS = float(os.getenv("DELIVERY_DELAY_MS", "40"))
DELIVERY_JITTER_MS = float(os.getenv("DELIVERY_JITTER_MS", "10"))
EMAIL_FAIL_RATE = float(os.getenv("EMAIL_FAIL_RATE", "0.01"))

# --------------------------------------------------------------- metrics ----
ORDERS = Counter("egift_orders_total", "eGift orders", ["status"])
LATENCY = Histogram(
    "egift_order_latency_seconds", "eGift order latency", ["status"],
    buckets=[0.1, 0.2, 0.5, 1, 2, 5, 10],
)
# FIX: a per-step histogram. The PDF measures only the whole order, so its dashboard
# cannot distinguish "activation is slow" from "email is slow" -- which is the exact
# point of Day 4's two experiments. With this, the dashboard can tell you too, not
# just the trace.
STEP_LATENCY = Histogram(
    "egift_step_latency_seconds", "Latency of each step in an order", ["step"],
    buckets=[0.01, 0.05, 0.1, 0.2, 0.5, 1, 2, 5],
)
BUILD_INFO = Gauge("egift_build_info", "Build metadata", ["version"])
BUILD_INFO.labels(version=VERSION).set(1)
IN_FLIGHT = Gauge("egift_in_flight_orders", "Orders currently being processed")


# --------------------------------------------------------------- logging ----
class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": _dt.datetime.fromtimestamp(record.created, tz=_dt.timezone.utc)
                  .isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname,
            "service": "egift",
            "version": VERSION,
            "msg": record.getMessage(),
        }
        extra = getattr(record, "extra", None)
        if isinstance(extra, dict):
            payload.update(extra)
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, separators=(",", ":"))


_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(JsonFormatter())
log = logging.getLogger("egift")
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
log.addHandler(_h)
log.propagate = False


class Order(BaseModel):
    customer_id: str
    amount: float
    recipient_email: str


@app.get("/healthz")
def healthz():
    return {"status": "ok", "version": VERSION}


@app.get("/readyz")
def readyz():
    return {"status": "ready", "version": VERSION}


def _fail(fields, start, status_code, reason, **more):
    elapsed = time.perf_counter() - start
    fields.update(status="error", reason=reason, latency_ms=round(elapsed * 1000), **more)
    log.error("order failed", extra={"extra": fields})
    ORDERS.labels(status="error").inc()
    LATENCY.labels(status="error").observe(elapsed)
    return PlainTextResponse(reason.replace("_", " "), status_code=status_code)


@app.post("/orders")
def create_order(order: Order):
    start = time.perf_counter()
    IN_FLIGHT.inc()
    order_id = uuid.uuid4().hex[:8]
    fields = {"order_id": order_id, "customer_id": order.customer_id, "amount": order.amount}
    try:
        # Auto-instrumentation only sees HTTP boundaries. For internal steps you care
        # about, you name the spans yourself. Attributes become searchable in Tempo.
        with tracer.start_as_current_span("generate_code") as span:
            t0 = time.perf_counter()
            code = f"EG-{random.randint(10**9, 10**10 - 1)}"
            time.sleep(0.01)
            span.set_attribute("egift.code_prefix", "EG")
            STEP_LATENCY.labels(step="generate_code").observe(time.perf_counter() - t0)

        # The outgoing requests.post is auto-instrumented: it injects W3C traceparent
        # headers, so the activation service's span becomes a child of this trace.
        # FIX: the PDF has no try/except here. If activation is unreachable,
        # requests raises ConnectionError, FastAPI returns a bare 500, and NEITHER the
        # metric nor the log records it. A dead dependency would be invisible to
        # everything you built on Days 2-3. That is the exact failure class this
        # series exists to teach you to catch.
        t0 = time.perf_counter()
        try:
            r = requests.post(
                ACTIVATION_URL,
                json={"card_number": code.replace("EG-", "6011"),
                      "amount": order.amount, "store_id": "EGIFT"},
                timeout=ACTIVATION_TIMEOUT_S,
            )
        except requests.exceptions.Timeout:
            STEP_LATENCY.labels(step="activate").observe(time.perf_counter() - t0)
            return _fail(fields, start, 504, "activation_timeout",
                         timeout_s=ACTIVATION_TIMEOUT_S)
        except requests.exceptions.RequestException as e:
            STEP_LATENCY.labels(step="activate").observe(time.perf_counter() - t0)
            return _fail(fields, start, 502, "activation_unreachable",
                         error=type(e).__name__)
        STEP_LATENCY.labels(step="activate").observe(time.perf_counter() - t0)

        if r.status_code != 200:
            return _fail(fields, start, 502, "activation_failed",
                         upstream_status=r.status_code)

        with tracer.start_as_current_span("send_email") as span:
            t0 = time.perf_counter()
            span.set_attribute("email.provider", "sendgrid-mock")
            span.set_attribute("email.recipient_domain",
                               order.recipient_email.split("@")[-1])
            time.sleep(max(0.0, random.gauss(DELIVERY_DELAY_MS, DELIVERY_JITTER_MS) / 1000))
            STEP_LATENCY.labels(step="send_email").observe(time.perf_counter() - t0)
            if random.random() < EMAIL_FAIL_RATE:
                span.set_attribute("email.delivered", False)
                return _fail(fields, start, 502, "email_delivery_failed")
            span.set_attribute("email.delivered", True)

        elapsed = time.perf_counter() - start
        fields.update(status="ok", latency_ms=round(elapsed * 1000))
        log.info("order fulfilled", extra={"extra": fields})
        ORDERS.labels(status="ok").inc()
        LATENCY.labels(status="ok").observe(elapsed)
        return JSONResponse({"order_id": order_id, "code": code,
                             "delivered_to": order.recipient_email, "version": VERSION})
    finally:
        IN_FLIGHT.dec()


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
