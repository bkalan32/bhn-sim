#!/usr/bin/env python3
"""Operational KPIs from the incident records — the table for docs/ops-kpis.md.

    tools/kpis.py            markdown table of every incident on the bot
    tools/kpis.py --json     raw

Columns:
  TTD  time to detect   = first alert - fault injected   (only when a drill note recorded the
                          fault time: "drill: fault injected at <iso>"; else "-")
  TTT  time to ticket   = opened - first alert            (group_wait + webhook)
  TTX  time to context  = context_attached - opened       (Day 10: the three lookups)
  TTH  time to hypothesis = ai_hypothesis attached - opened
  dur  duration_min on the record
  notes / drafts / hypothesis present, and the AI's latency + tokens
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone

CTX = os.getenv("KUBE_CONTEXT", "kind-bhn-sim")
PROXY = "/api/v1/namespaces/payments/services/incident-bot:8020/proxy"
DIRECT = os.getenv("INCIDENT_BOT_URL", "")


def get(path):
    if DIRECT:
        with urllib.request.urlopen(DIRECT + path, timeout=10) as r:
            return json.loads(r.read())
    r = subprocess.run(["kubectl", "--context", CTX, "get", "--raw", PROXY + path], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr); sys.exit(1)
    return json.loads(r.stdout)


def iso_to_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None


def secs(a, b):
    return None if a is None or b is None else round(b - a)


def fmt(v, unit="s"):
    return "-" if v is None else (f"{v}{unit}" if unit == "s" else f"{v}")


def row(inc):
    tl = inc.get("timeline", [])
    ev = lambda name: next((e for e in tl if e.get("event") == name), None)
    fault = None
    for e in tl:
        if e.get("event") == "note":
            m = re.search(r"fault injected at (\S+)", e.get("text", ""))
            if m:
                fault = iso_to_ts(m.group(1))
    first = inc.get("first_alert_at"); opened = inc.get("opened_at")
    ctx = ev("context_attached"); hyp = next((e for e in tl if e.get("event") == "ai_draft_attached" and e.get("draft") == "hypothesis"), None)
    meta = inc.get("ai_meta", {})
    notes = sum(1 for e in tl if e.get("event") == "note" and not e.get("text", "").startswith("drill:"))
    return {
        "id": inc["id"], "service": inc.get("service"), "opened": (inc.get("opened_at_iso") or "")[:16],
        "alerts": ",".join(inc.get("alerts", [])),
        "ttd_s": secs(fault, first), "ttt_s": secs(first, opened),
        "ttx_s": secs(opened, ctx["ts"]) if ctx else None,
        "tth_s": secs(opened, hyp["ts"]) if hyp else None,
        "dur_min": inc.get("duration_min"), "notes": notes,
        "drafts": "".join(k[0] for k in ("open", "resolved", "hypothesis") if meta.get(k, {}).get("ok")),
        "ai_ms": sum(v.get("latency_ms") or 0 for v in meta.values()),
        "tokens": sum((v.get("input_tokens") or 0) + (v.get("output_tokens") or 0) for v in meta.values()),
        "context": "ok" if inc.get("context") and all(m.get("ok") for m in inc.get("context_meta", {}).values()) else ("partial" if inc.get("context") else "-"),
    }


def main():
    incs = [get(f"/incidents/{i['id']}") for i in get("/incidents")]
    rows = [row(i) for i in sorted(incs, key=lambda i: i.get("opened_at", 0))]
    if "--json" in sys.argv:
        print(json.dumps(rows, indent=2)); return
    print("| Record | Service | Opened (UTC) | Alerts | TTD | TTT | TTX | TTH | Dur (min) | Notes | Drafts | AI ms | Tokens | Context |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| `{r['id']}` | {r['service']} | {r['opened']} | {r['alerts']} | {fmt(r['ttd_s'])} | {fmt(r['ttt_s'])} | "
              f"{fmt(r['ttx_s'])} | {fmt(r['tth_s'])} | {fmt(r['dur_min'], '')} | {r['notes']} | {r['drafts'] or '-'} | "
              f"{r['ai_ms'] or '-'} | {r['tokens'] or '-'} | {r['context']} |")
    print()
    print("TTD = fault -> first alert (drill notes only) · TTT = first alert -> ticket · TTX = ticket -> context · "
          "TTH = ticket -> hypothesis · Drafts: o=open r=resolved h=hypothesis")


if __name__ == "__main__":
    main()
