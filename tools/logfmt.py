#!/usr/bin/env python3
"""Pretty-print JSON log lines from stdin — any service.

Prints level, msg, then every remaining field as k=v. Non-JSON lines pass through
marked. Exists so no shell script embeds Python with escaped quotes (that is a
SyntaxError on 3.12 and a silent mess elsewhere).
"""
import json
import sys

SKIP = {"ts", "level", "service", "version", "msg", "span_id"}
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        d = json.loads(raw)
    except ValueError:
        print(f"  (not JSON) {raw[:110]}")
        continue
    rest = " ".join(f"{k}={v}" for k, v in d.items() if k not in SKIP)
    print(f"  {str(d.get('level', '?')):<5} {str(d.get('msg', '')):<44} {rest}".rstrip())
