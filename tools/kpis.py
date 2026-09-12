#!/usr/bin/env python3
"""Operational KPIs from the incident records — the table for docs/ops-kpis.md.

    tools/kpis.py                     markdown table of every incident on the bot
    tools/kpis.py --json              raw
    tools/kpis.py --summary [--days 7] [--json]
                                      Day 18: the seven KPIs (docs/ops-kpis.md "The KPI set"), each with
                                      its definition, source and current value — the report reads the JSON

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


# ------------------------------------------------------------- Day 18: the KPI set ---
PROM = "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/query"
REM = "/api/v1/namespaces/payments/services/remediator:8030/proxy"


def raw(path):
    r = subprocess.run(["kubectl", "--context", CTX, "get", "--raw", path], capture_output=True, text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def promql(q):
    import urllib.parse
    d = raw(PROM + "?query=" + urllib.parse.quote(q))
    try:
        res = d["data"]["result"]
        return float(res[0]["value"][1]) if res else None
    except Exception:
        return None


def promql_by(q, label):
    import urllib.parse
    d = raw(PROM + "?query=" + urllib.parse.quote(q))
    try:
        return {r["metric"].get(label, "-"): float(r["value"][1]) for r in d["data"]["result"]}
    except Exception:
        return {}


def jenkins_builds(job, days):
    """Deploy frequency needs Jenkins. Auth from JENKINS_USER/JENKINS_PASS; absent -> no data."""
    import base64
    u, pw = os.getenv("JENKINS_USER", ""), os.getenv("JENKINS_PASS", "")
    url = os.getenv("JENKINS_URL", "http://localhost:8081").rstrip("/")
    if not (u and pw):
        return None, "no data (set JENKINS_USER/JENKINS_PASS)"
    req = urllib.request.Request(f"{url}/job/{job}/api/json?tree=builds[number,result,timestamp,actions[parameters[name,value]]]{{0,60}}",
                                 headers={"Authorization": "Basic " + base64.b64encode(f"{u}:{pw}".encode()).decode()})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            builds = json.loads(r.read()).get("builds", [])
    except Exception as e:  # noqa: BLE001
        return None, f"no data ({type(e).__name__})"
    since = (datetime.now(timezone.utc).timestamp() - days * 86400) * 1000
    recent = [b for b in builds if b.get("timestamp", 0) >= since]
    return recent, "ok"


def summary(days=7):
    now = datetime.now(timezone.utc).timestamp(); since = now - days * 86400
    incs = [get(f"/incidents/{i['id']}") for i in get("/incidents")]
    rows = [row(i) for i in incs]
    window = [r for r, i in zip(rows, incs) if i.get("opened_at", 0) >= since]
    win_incs = [i for i in incs if i.get("opened_at", 0) >= since]
    mean = lambda xs: (round(sum(xs) / len(xs), 1) if xs else None)
    # 1 MTTD — drills only (the fault time is on the record); 2 MTTR — resolved incidents
    ttd_all = [r["ttd_s"] for r in rows if r["ttd_s"] is not None]; ttd_win = [r["ttd_s"] for r in window if r["ttd_s"] is not None]
    dur_all = [i["duration_min"] for i in incs if i.get("duration_min") is not None]; dur_win = [i["duration_min"] for i in win_incs if i.get("duration_min") is not None]
    # 3 incidents / week by service (records; PromQL twin below needs the Day 18 bot)
    by_svc = {}
    for i in win_incs:
        by_svc[i.get("service", "-")] = by_svc.get(i.get("service", "-"), 0) + 1
    # 4 remediation share: incidents in the window with an auto/approved action that succeeded
    hist = raw(REM + "/actions") or []
    hist = hist if isinstance(hist, list) else hist.get("actions", hist.get("history", []))
    remediated = {h.get("incident") for h in hist if h.get("mode") in ("auto", "approved") and h.get("result") == "ok"}
    declined = {h.get("incident") for h in hist if h.get("mode") == "declined"}
    win_ids = {i["id"] for i in win_incs}
    share = round(100 * len(remediated & win_ids) / len(win_ids), 1) if win_ids else None
    # 5 error budgets remaining (30d), both SLOs
    eb_avail = promql('100 * (1 - (1 - sum(increase(activation_requests_total{status="ok"}[30d])) / clamp_min(sum(increase(activation_requests_total[30d])), 1)) / 0.005)')
    eb_lat = promql('100 * (1 - (1 - sum(increase(activation_latency_seconds_bucket{le="0.3"}[30d])) / clamp_min(sum(increase(activation_latency_seconds_count[30d])), 1)) / 0.01)')
    # 6 alert precision: alert NAMES that fired in the window vs those that reached a ticket
    fired = promql_by(f'count by (alertname) (count_over_time(ALERTS{{alertstate="firing"}}[{days}d]))', "alertname")
    fired_names = {n for n in fired if n != "Watchdog"}
    ticketed = {a for i in win_incs for a in i.get("alerts", [])}
    precision = round(100 * len(fired_names & ticketed) / len(fired_names), 1) if fired_names else None
    # 7 deploy frequency + failure rate (Jenkins)
    builds, jmeta = jenkins_builds("deploy-service", days)
    if builds is not None:
        fails = [b for b in builds if b.get("result") in ("FAILURE", "ABORTED")]
        deploys = {"builds": len(builds), "failed": len(fails), "failure_rate_pct": round(100 * len(fails) / len(builds), 1) if builds else None, "per_day": round(len(builds) / days, 2)}
    else:
        deploys = {"note": jmeta}
    return {
        "window_days": days, "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mttd_s": {"window": mean(ttd_win), "all_time": mean(ttd_all), "n_window": len(ttd_win), "n_all": len(ttd_all),
                   "definition": "first alert - fault injected (drill notes on the record); non-drill incidents have no fault time"},
        "mttr_min": {"window": mean(dur_win), "all_time": mean(dur_all), "n_window": len(dur_win), "n_all": len(dur_all),
                     "definition": "resolved - opened (duration_min on the record); includes the alerts' resolve windows"},
        "incidents_by_service": {"window": by_svc, "total": len(win_incs), "promql": f"sum by (service) (increase(incidents_created_total[{days}d]))"},
        "remediation_share_pct": {"window": share, "remediated_incidents": sorted(remediated & win_ids), "declined": sorted(declined & win_ids),
                                  "promql": f'sum(increase(remediation_actions_total{{mode=~"auto|approved",result="ok"}}[{days}d])) / sum(increase(incidents_created_total[{days}d]))'},
        "error_budget_remaining_pct": {"availability_30d": None if eb_avail is None else round(eb_avail, 1), "latency_30d": None if eb_lat is None else round(eb_lat, 1)},
        "alert_precision_pct": {"window": precision, "fired": sorted(fired_names), "ticketed": sorted(fired_names & ticketed), "noise": sorted(fired_names - ticketed),
                                "definition": "alert names that reached a ticket / alert names that fired (Watchdog excluded); coarse by design — a name is the unit the audit judges"},
        "deploys": {**deploys, "source": "Jenkins deploy-service builds"},
    }


def print_summary(d):
    f = lambda v, u="": ("no data" if v is None else f"{v}{u}")
    print(f"KPIs — last {d['window_days']} days (generated {d['generated_at']})")
    print(f"| KPI | value ({d['window_days']}d) | all time | source |")
    print("|---|---|---|---|")
    print(f"| MTTD (fault → first alert) | {f(d['mttd_s']['window'],' s')} (n={d['mttd_s']['n_window']}) | {f(d['mttd_s']['all_time'],' s')} (n={d['mttd_s']['n_all']}) | incident records (drill notes) |")
    print(f"| MTTR (opened → resolved) | {f(d['mttr_min']['window'],' min')} (n={d['mttr_min']['n_window']}) | {f(d['mttr_min']['all_time'],' min')} (n={d['mttr_min']['n_all']}) | `duration_min` on the record |")
    bs = ", ".join(f"{k} {v}" for k, v in sorted(d['incidents_by_service']['window'].items())) or "none"
    print(f"| Incidents / week by service | {d['incidents_by_service']['total']}: {bs} | – | records; PromQL `{d['incidents_by_service']['promql']}` |")
    print(f"| % incidents auto/approved-remediated | {f(d['remediation_share_pct']['window'],' %')} ({len(d['remediation_share_pct']['remediated_incidents'])} of {d['incidents_by_service']['total']}) | – | remediator history; PromQL twin in docs |")
    eb = d['error_budget_remaining_pct']
    print(f"| Error budget remaining (30d) | availability {f(eb['availability_30d'],' %')} · latency {f(eb['latency_30d'],' %')} | – | recording rules / Prometheus |")
    ap = d['alert_precision_pct']
    print(f"| Alert precision | {f(ap['window'],' %')} ({len(ap['ticketed'])} of {len(ap['fired'])} names) — noise: {', '.join(ap['noise']) or 'none'} | – | Prometheus ALERTS × records |")
    dp = d['deploys']
    dtxt = dp.get('note') or f"{dp['builds']} builds ({dp['per_day']}/day), {dp['failed']} failed = {f(dp['failure_rate_pct'],' %')}"
    print(f"| Deploy frequency / failure rate | {dtxt} | – | Jenkins deploy-service |")


def main():
    if "--summary" in sys.argv:
        days = int(sys.argv[sys.argv.index("--days") + 1]) if "--days" in sys.argv else 7
        d = summary(days)
        print(json.dumps(d, indent=2)) if "--json" in sys.argv else print_summary(d)
        return
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
