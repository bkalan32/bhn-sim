"""
loadgen — the fake store network and the fake corporate customers. Day 21, chore 3.

Days 2-20 ran this from two laptop terminals (12-loadgen.sh, 33-loadgen-egift.sh). That had
three costs the lab kept paying: traffic stopped whenever a terminal closed or Docker
restarted; a first deploy could not be verified because nothing could send traffic before
there were pods (CORRECTIONS-REBUILD B5/B6); and "is the load generator up?" had no answer
anywhere but a terminal window. Mission Control needs traffic to be a KNOB, and a knob needs
an object in the cluster to turn.

Now it is a container in the `loadgen` Deployment (k8s/loadgen.yaml), one container per
target, configured by environment:

  TARGET_URL        where to send (in-cluster Service DNS)
  PAYLOAD           activation | egift
  BASE_RPS          the normal rate for this target
  RATE_MULTIPLIER   0-10, default 1. 0 = paused (the Day 25 "traffic loss" fault); 2 = a
                    busy Saturday. A value outside 0-10 refuses to start: a typo must not
                    become a load test.
  METRICS_PORT      Prometheus text on /metrics: requests by outcome, the target rate and
                    the multiplier — so "is traffic flowing, and was it turned down on
                    purpose?" is a query, not a guess.

The laptop scripts still work (tools/loadgen.py runs this file with --url/--rps) for the
days you want traffic from outside the cluster through the NodePort.

Kept from Day 2 (the PDF's bug): no `except: pass`. Every 5 s a summary line with counts by
outcome, and a loud line when nothing is getting through.
"""

import argparse
import http.server
import json
import os
import random
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import Counter


def parse_multiplier(raw) -> float:
    """'1' -> 1.0. Empty -> 1.0. Anything not a number in [0, 10] -> ValueError."""
    if raw is None or str(raw).strip() == "":
        return 1.0
    v = float(str(raw).strip())
    if not 0.0 <= v <= 10.0:
        raise ValueError(f"RATE_MULTIPLIER={raw}: must be between 0 and 10")
    return v


def effective_rps(base: float, mult: float) -> float:
    return max(0.0, float(base) * float(mult))


def make_body(payload: str) -> dict:
    if payload == "egift":
        return {"customer_id": f"CORP-{random.randint(1, 500):04d}",
                "amount": random.choice([25, 50, 100]),
                "recipient_email": f"rep{random.randint(1, 9999)}@corp{random.randint(1, 500)}.example"}
    return {"card_number": f"6011{random.randint(10**11, 10**12 - 1)}",
            "amount": random.choice([25, 50, 100]),
            "store_id": f"STORE-{random.randint(1, 500):04d}"}


def outcome(url, body, timeout) -> str:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return str(r.status)
    except urllib.error.HTTPError as e:
        return str(e.code)                        # 500/502/503/504: the service answered, badly
    except Exception as e:  # noqa: BLE001
        return f"unreachable_{type(e).__name__}"   # nothing answered at all


class Metrics:
    def __init__(self, target: str, rps: float, mult: float):
        self.target, self.rps, self.mult = target, rps, mult
        self.counts = Counter()
        self.lock = threading.Lock()

    def inc(self, code):
        with self.lock:
            self.counts[code] += 1

    def render(self) -> str:
        t = self.target
        lines = ["# HELP loadgen_requests_total Requests sent, by outcome (HTTP code or unreachable_*)",
                 "# TYPE loadgen_requests_total counter"]
        with self.lock:
            for code, n in sorted(self.counts.items()):
                lines.append(f'loadgen_requests_total{{target="{t}",outcome="{code}"}} {n}')
        lines += ["# HELP loadgen_target_rps The rate this generator is trying to send (BASE_RPS x RATE_MULTIPLIER)",
                  "# TYPE loadgen_target_rps gauge", f'loadgen_target_rps{{target="{t}"}} {self.rps}',
                  "# HELP loadgen_rate_multiplier The RATE_MULTIPLIER knob (0 = paused on purpose)",
                  "# TYPE loadgen_rate_multiplier gauge", f'loadgen_rate_multiplier{{target="{t}"}} {self.mult}']
        return "\n".join(lines) + "\n"


def serve_metrics(metrics: Metrics, port: int):
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/metrics"):
                body, ctype = metrics.render().encode(), "text/plain; version=0.0.4"
            elif self.path.startswith("/healthz"):
                body, ctype = b'{"status":"ok"}', "application/json"
            else:
                self.send_response(404); self.end_headers(); return
            self.send_response(200); self.send_header("Content-Type", ctype); self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True, name="metrics").start()
    return srv


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--url", default=os.getenv("TARGET_URL", "http://localhost:8000/activate"))
    p.add_argument("--payload", choices=["activation", "egift"], default=os.getenv("PAYLOAD", "activation"))
    p.add_argument("--rps", type=float, default=float(os.getenv("BASE_RPS", "8")), help="base requests per second")
    p.add_argument("--multiplier", default=os.getenv("RATE_MULTIPLIER", "1"), help="0-10; 0 pauses")
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--metrics-port", type=int, default=int(os.getenv("METRICS_PORT", "0")), help="0 = no /metrics")
    a = p.parse_args(argv)
    try:
        mult = parse_multiplier(a.multiplier)
    except ValueError as e:
        print(f"refusing to start: {e}", file=sys.stderr, flush=True)
        return 2
    rps = effective_rps(a.rps, mult)
    m = Metrics(a.payload, rps, mult)
    if a.metrics_port:
        serve_metrics(m, a.metrics_port)
    print(f"load generator [{a.payload}] -> {a.url}   base {a.rps} req/s x {mult} = {rps} req/s", flush=True)

    window, last = Counter(), time.time()
    try:
        while True:
            if rps <= 0:
                # Paused on purpose. Still alive, still scraped: loadgen_rate_multiplier=0 is
                # how a responder tells "someone turned traffic off" from "the generator died".
                print(f"[{time.strftime('%H:%M:%S')}] paused (RATE_MULTIPLIER={mult}) — sending nothing", flush=True)
                time.sleep(30)
                continue
            code = outcome(a.url, make_body(a.payload), a.timeout)
            m.inc(code)
            window[code] += 1
            now = time.time()
            if now - last >= 5:
                rate = sum(window.values()) / (now - last)
                print(f"[{time.strftime('%H:%M:%S')}] {rate:5.1f} req/s   "
                      + "  ".join(f"{k}={v}" for k, v in sorted(window.items())), flush=True)
                if all(k.startswith("unreachable") for k in window):
                    print("  ^ nothing is reaching the service", file=sys.stderr, flush=True)
                window.clear()
                last = now
            time.sleep(max(0.0, random.expovariate(rps)))
    except KeyboardInterrupt:
        print(f"\nstopped — totals: {dict(sorted(m.counts.items()))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
