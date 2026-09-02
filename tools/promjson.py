#!/usr/bin/env python3
"""Parse Prometheus HTTP API responses from stdin.

Exists because inline `python3 -c '...'` with escaped quotes is a quoting minefield
in bash -- a real file has no escaping problem at all.

Usage:
    curl .../api/v1/targets | promjson.py targets [name-substring]
    curl .../api/v1/query   | promjson.py value [format]
"""
import json
import sys


def load():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def targets(match="activation"):
    d = load().get("data", {}).get("activeTargets", [])
    hits = [
        x for x in d
        if match in (x.get("labels", {}).get("job", "") + x.get("scrapePool", ""))
    ]
    if not hits:
        print(f"  no targets matching '{match}' found")
        print("  -> the ServiceMonitor's release: label must match the Helm release name")
        return 1
    for x in hits:
        health = x.get("health", "?")
        pod = x.get("labels", {}).get("pod", "?")
        print(f"  {health:<8} {pod:<32} {x.get('scrapeUrl','')}")
        if health != "up":
            print(f"      lastError: {x.get('lastError') or '(none)'}")
    return 0 if all(x.get("health") == "up" for x in hits) else 1


def value(fmt="{:.4f}"):
    r = load().get("data", {}).get("result", [])
    if not r:
        print("no data")
        return 0
    try:
        v = float(r[0]["value"][1])
    except (KeyError, IndexError, ValueError, TypeError):
        print("no data")
        return 0
    print("no data" if v != v else fmt.format(v))  # v != v catches NaN
    return 0


def rules(match="activation"):
    d = load().get("data", {}).get("groups", [])
    n = 0
    for g in d:
        for r in g.get("rules", []):
            if r.get("type") != "alerting":
                continue
            if match not in (r.get("name", "") + g.get("name", "")):
                continue
            n += 1
            state = r.get("state", "unknown")
            mark = {"inactive": "ok", "pending": "PENDING", "firing": "FIRING"}.get(state, state)
            sev = r.get("labels", {}).get("severity", "?")
            print(f"  {mark:<8} {r.get('name',''):<28} severity={sev}")
    if not n:
        print("  no matching alert rules loaded")
        return 1
    return 0


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "value"
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    if mode == "targets":
        sys.exit(targets(arg or "activation"))
    if mode == "rules":
        sys.exit(rules(arg or "activation"))
    sys.exit(value(arg or "{:.4f}"))
