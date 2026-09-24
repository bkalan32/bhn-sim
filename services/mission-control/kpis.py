"""
kpis.py — Day 24 Step 2: the seven Day 18 KPIs (docs/ops-kpis.md), as tiles with a 4-week trend,
and the incident table they are computed from.

Pure functions over what app.py fetched (the bot's full incident records, the game-day runs, the
remediator's history, Jenkins builds, a few PromQL results) — so every number here is testable
without a cluster, and every definition is written once, next to its code, and shown in the tooltip.

What changed since Day 18's tools/kpis.py:
  * MTTD is COMPUTED for console-run incidents: the fault's injection time is on the run record
    (gameday.injection_for), not in a hand-written "drill: fault injected at" note. The note still
    counts for older drills. Each value says which source it came from.
  * MTTR excludes incidents a human CLOSED (close_incident: the resolve webhook was lost to a
    restart). Their "duration" is how long nobody noticed, not how long the outage lasted — INC-0023's
    227.9 min (CORRECTIONS-DAY22) and the two reboot leftovers of Day 23. The tile says how many.
"""

import calendar
import re
import time

import gameday

WEEK = 7 * 86400
WEEKS = 4

DEFINITIONS = {
    "mttd": "Mean time to detect: first alert (Prometheus startsAt) − fault injected. The injection time comes from the "
            "game-day run that injected it, or a 'drill: fault injected at …' note. Incidents with no known injection "
            "(real faults) are excluded — the tile says how many were counted.",
    "mttr": "Mean time to resolve: resolved − opened (duration_min on the record), over incidents resolved by their alerts. "
            "Includes the alerts' own resolve windows (≈5 min here, by design). Incidents a human closed by hand are excluded.",
    "incidents": "Incidents opened in the week, by the service on the record. Game days inflate it on purpose.",
    "remediation": "Share of the week's incidents with at least one remediator action of mode auto or approved that "
                   "succeeded. Tier 3 can never count — that is the policy. The remediator keeps its history in memory: "
                   "'no data' after a restart, not 0 %.",
    "error_budget": "Per SLO, 100 × (1 − (1 − SLI over 30 d) / budget): availability 99.5 % (budget 0.5 %), latency 99 % "
                    "under 300 ms (budget 1 %). Prometheus keeps 10 days here, so '30 d' means 'what it still has'.",
    "precision": "Alert names that reached a ticket ÷ alert names that fired at all in the week (Watchdog excluded). "
                 "Coarse on purpose: the name is what the alert audit judges.",
    "deploys": "deploy-service builds per day in the week, and the share that failed or were aborted (a Verify "
               "rollback is a failed build — that is the point). Needs the Jenkins token (210-mc-config.sh).",
}


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def iso_ts(s):
    if not s:
        return None
    try:
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def ttd(inc: dict, runs: list):
    """(seconds, source) — or (None, None) when no injection is known."""
    first = inc.get("first_alert_at")
    inj = gameday.injection_for(inc, runs)
    if inj and first:
        return round(first - inj["fired_at"]), f"{inj['run']} step {inj['step']} ({inj['target']} {inj['knob']})"
    for e in inc.get("timeline", []):
        if e.get("event") == "note":
            m = re.search(r"fault injected at (\S+)", e.get("text", ""))
            if m and first and iso_ts(m.group(1)):
                return round(first - iso_ts(m.group(1))), "drill note"
    return None, None


def weeks(now: float):
    """Four [start, end) windows, oldest first — the trend reads left to right."""
    return [(now - WEEK * (k + 1), now - WEEK * k) for k in reversed(range(WEEKS))]


def in_week(ts, w):
    return ts is not None and w[0] <= ts < w[1]


def table(incidents: list, runs: list, rem_hist: list, feeding: dict) -> list:
    modes = {}
    for h in rem_hist or []:
        if h.get("incident"):
            modes.setdefault(h["incident"], set()).add(f"{h.get('mode')}:{h.get('result')}")
    rows = []
    for i in incidents:
        t, src = ttd(i, runs)
        closed = i.get("closed_by_human") or {}
        fd = feeding.get(i["id"]) or {}
        rows.append({
            "id": i["id"], "service": i.get("service"), "severity": i.get("severity"), "status": i.get("status"),
            "alerts": i.get("alerts", []), "opened_at_iso": i.get("opened_at_iso"), "first_alert_at_iso": i.get("first_alert_at_iso"),
            "ttd_s": t, "ttd_source": src,
            "ttt_s": round(i["opened_at"] - i["first_alert_at"]) if i.get("opened_at") and i.get("first_alert_at") else None,
            "duration_min": i.get("duration_min"), "closed_by_human": bool(closed), "closed_reason": closed.get("reason"),
            "remediation": sorted(modes.get(i["id"], [])),
            "kb": fd.get("decision"), "kb_id": fd.get("kb_id"),
        })
    return sorted(rows, key=lambda r: r["opened_at_iso"] or "", reverse=True)


def compute(incidents: list, runs: list, rem_hist: list | None, builds: list | None, prom: dict, feeding: dict,
            now: float | None = None) -> dict:
    now = now or time.time()
    ws = weeks(now)
    rows = table(incidents, runs, rem_hist or [], feeding)
    by_id = {i["id"]: i for i in incidents}

    def opened_in(w):
        return [i for i in incidents if in_week(i.get("opened_at"), w)]

    # 1 MTTD
    mttd_w, mttd_n = [], []
    for w in ws:
        vals = [r["ttd_s"] for r in rows if r["ttd_s"] is not None and in_week(by_id[r["id"]].get("opened_at"), w)]
        mttd_w.append(mean(vals)); mttd_n.append(len(vals))
    console = [r for r in rows if r["ttd_source"] and r["ttd_source"].startswith("run-")]
    # 2 MTTR — resolved by their alerts only
    mttr_w, excluded = [], 0
    for w in ws:
        vals = []
        for i in incidents:
            if i.get("status") == "resolved" and in_week(i.get("resolved_at"), w):
                if i.get("closed_by_human"):
                    excluded += 1 if w is ws[-1] else 0
                    continue
                vals.append(i.get("duration_min"))
        mttr_w.append(mean(vals))
    # 3 incidents per week, by service
    counts = [len(opened_in(w)) for w in ws]
    by_svc = {}
    for i in opened_in(ws[-1]):
        by_svc[i.get("service") or "-"] = by_svc.get(i.get("service") or "-", 0) + 1
    # 4 remediation share
    rem_ok = {h.get("incident") for h in (rem_hist or []) if h.get("mode") in ("auto", "approved") and h.get("result") == "ok"}
    share_w = []
    for w in ws:
        ids = {i["id"] for i in opened_in(w)}
        share_w.append(round(100 * len(ids & rem_ok) / len(ids), 1) if ids and rem_hist else None)
    # 5 error budget (PromQL, one value per week-end)
    eb_a, eb_l = prom.get("eb_avail", [None] * WEEKS), prom.get("eb_lat", [None] * WEEKS)
    # 6 alert precision (fired names per week from PromQL, ticketed names from the records)
    prec_w, noise = [], []
    for k, w in enumerate(ws):
        fired = {n for n in (prom.get("fired", [None] * WEEKS)[k] or []) if n != "Watchdog"}
        ticketed = {a for i in opened_in(w) for a in i.get("alerts", [])}
        prec_w.append(round(100 * len(fired & ticketed) / len(fired), 1) if fired else None)
        if k == WEEKS - 1:
            noise = sorted(fired - ticketed)
    # 7 deploys
    dep_w, fail_w = [], []
    for w in ws:
        bs = [b for b in (builds or []) if in_week((b.get("timestamp") or 0) / 1000, w) and b.get("result")]
        dep_w.append(round(len(bs) / 7, 2) if builds is not None else None)
        fail_w.append(round(100 * sum(b.get("result") in ("FAILURE", "ABORTED") for b in bs) / len(bs), 1) if bs else None)

    def tile(key, title, trend, unit, detail="", n=None):
        return {"key": key, "title": title, "value": trend[-1], "unit": unit, "trend": trend, "n": n,
                "definition": DEFINITIONS[key], "detail": detail}

    tiles = [
        tile("mttd", "MTTD", mttd_w, "s", f"{mttd_n[-1]} incident(s) with a known injection this week; "
             f"{len(console)} measured from console runs overall", n=mttd_n[-1]),
        tile("mttr", "MTTR", mttr_w, "min", f"{excluded} closed by hand this week, excluded" if excluded else ""),
        tile("incidents", "Incidents / week", counts, "", ", ".join(f"{k} {v}" for k, v in sorted(by_svc.items())) or "none this week"),
        tile("remediation", "Auto / approved remediation", share_w, "%",
             "" if rem_hist else "no data — the remediator's history starts at its last restart"),
        {**tile("error_budget", "Error budget remaining", eb_a, "%", "availability; latency beside it"), "second": eb_l,
         "second_label": "latency"},
        tile("precision", "Alert precision", prec_w, "%", ("noise: " + ", ".join(noise)) if noise else ""),
        {**tile("deploys", "Deploys / day", dep_w, "/day",
                "no data — Jenkins not configured" if builds is None else f"{fail_w[-1] if fail_w[-1] is not None else 0} % failed this week"),
         "second": fail_w, "second_label": "failed %"},
    ]
    return {"generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "weeks": [time.strftime("%Y-%m-%d", time.gmtime(w[0])) for w in ws], "tiles": tiles, "incidents": rows}
