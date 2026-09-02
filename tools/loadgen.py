"""
Your fake store network. Leave it running all day.

FIX vs the PDF: the printed version wraps the request in `except Exception: pass`,
so a dead port-forward looks exactly like a working one — the script keeps running
happily while zero traffic reaches the cluster. That is the actual cause of the
PDF's own "dashboard flat" troubleshooting entry.

This version prints a rolling summary every 5 seconds, so a broken port-forward is
obvious within one line of output.
"""

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request
from collections import Counter

p = argparse.ArgumentParser()
p.add_argument("--url", default=os.getenv("ACTIVATION_URL", "http://localhost:8000/activate"))
p.add_argument("--rps", type=float, default=8.0, help="approximate requests per second")
p.add_argument("--timeout", type=float, default=5.0)
p.add_argument("--payload", choices=["activation", "egift"], default="activation",
               help="which service's request body to send")
args = p.parse_args()


def make_body():
    if args.payload == "egift":
        # A corporate customer ordering digital gift cards for their sales team.
        return {
            "customer_id": f"CORP-{random.randint(1, 500):04d}",
            "amount": random.choice([25, 50, 100]),
            "recipient_email": f"rep{random.randint(1, 9999)}@corp{random.randint(1, 500)}.example",
        }
    return {
        "card_number": f"6011{random.randint(10**11, 10**12 - 1)}",
        "amount": random.choice([25, 50, 100]),
        "store_id": f"STORE-{random.randint(1, 500):04d}",
    }

tally = Counter()
window = Counter()
started = time.time()
last_report = started

print(f"load generator [{args.payload}] -> {args.url}   (~{args.rps} req/s)   Ctrl-C to stop", flush=True)

try:
    while True:
        body = json.dumps(make_body()).encode()
        req = urllib.request.Request(
            args.url, data=body, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=args.timeout) as r:
                key = str(r.status)
        except urllib.error.HTTPError as e:
            key = str(e.code)                      # 500/503 are the service failing
        except Exception as e:                     # noqa: BLE001
            key = f"unreachable ({type(e).__name__})"  # this is a BROKEN PORT-FORWARD
        tally[key] += 1
        window[key] += 1

        now = time.time()
        if now - last_report >= 5:
            rate = sum(window.values()) / (now - last_report)
            summary = "  ".join(f"{k}={v}" for k, v in sorted(window.items()))
            print(f"[{time.strftime('%H:%M:%S')}] {rate:5.1f} req/s   {summary}", flush=True)
            if all("unreachable" in k for k in window):
                print("  ^ nothing is reaching the service. Is the port-forward still up?",
                      file=sys.stderr, flush=True)
            window.clear()
            last_report = now

        time.sleep(max(0.0, random.expovariate(args.rps)))
except KeyboardInterrupt:
    elapsed = time.time() - started
    print(f"\nstopped after {elapsed:.0f}s — totals: {dict(sorted(tally.items()))}")
