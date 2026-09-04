#!/usr/bin/env python3
"""Parse Alertmanager v2 API responses from stdin (same idea as promjson.py).

    alertmanager_get /api/v2/alerts?active=true | amjson.py routing   who goes where
    alertmanager_get /api/v2/alerts?active=true | amjson.py names     alert names only
"""
import json
import sys


def load():
    try:
        return json.load(sys.stdin)
    except Exception:
        return []


def routing():
    alerts = load()
    ours = [a for a in alerts if a.get("labels", {}).get("service")]
    noise = [a for a in alerts if not a.get("labels", {}).get("service")]
    print(f"  {len(ours)} alert(s) with a service label -> incident-bot")
    for a in ours:
        l = a["labels"]
        print(f"     {l.get('alertname', '?'):<32} service={l.get('service'):<12} severity={l.get('severity')}")
    names = sorted({a.get("labels", {}).get("alertname", "?") for a in noise})
    print(f"  {len(noise)} alert(s) without one -> null   ({', '.join(names[:6])}{'...' if len(names) > 6 else ''})")
    print("  Watchdog is meant to be in that second list forever: it is Alertmanager's heartbeat.")


def names():
    print(", ".join(sorted({a.get("labels", {}).get("alertname", "?") for a in load()})) or "nothing")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "routing"
    {"routing": routing, "names": names}.get(mode, routing)()
