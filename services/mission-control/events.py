"""
events.py — the live feed. One broker, many browser tabs.

Every subscriber (an open GET /api/events) gets its own bounded asyncio.Queue. publish() puts
the event on every queue without waiting; a subscriber that cannot keep up (a tab asleep in the
background) loses its OLDEST events, never blocks the publisher — a slow browser must not be
able to slow down the Alertmanager webhook that feeds everyone else.

Event kinds (the `event:` field of the SSE message):
  hello     sent once on connect: the server's time and the kinds to expect
  alert     from Alertmanager's webhook (/hooks/alertmanager): status, alertname, service,
            severity, startsAt — one event per alert in the notification
  audit     every audit row as it is written (so a button press in one tab shows in another)
  approval  created / approved / declined / expired — and (Day 22) `proposed`, when the
            remediator queues one of its own (seen by the poller)
  health    the four health scores, every 15 s (the poller in app.py)
  incident  (Day 22) opened / resolved — the poller diffs the bot's open list every 15 s
  deploy    (Day 22) a new deploy/rollback annotation the pipeline wrote to Grafana
  gameday   (Day 24) a run started / a sealed step fired / aborted / revealed at Retro
  report    (Day 24) a daily report arrived at the bot after "Generate now"

The heartbeat is sse-starlette's `ping` (a comment line every 15 s): `kubectl port-forward`
and most proxies close a stream that has been silent for a while (PDF troubleshooting note).
"""

import asyncio
import itertools
import time

KINDS = ("hello", "alert", "audit", "approval", "health", "incident", "deploy", "gameday", "report")
# Day 24: everything but the 15-s health pulse is KEPT (db.feed) — a game-day run's timeline is read
# back from it at Retro, so the scribe's draft is the feed the responders watched.
KEPT = ("alert", "audit", "approval", "incident", "deploy", "gameday", "report")


class Broker:
    def __init__(self, maxsize: int = 200):
        self.maxsize = maxsize
        self.subscribers: set[asyncio.Queue] = set()
        self.seq = itertools.count(1)
        self.last: dict[str, dict] = {}          # last event of each kind — replayed to a new tab
        self.on_publish = None                   # Day 24: app.py persists KEPT kinds through this

    def subscribe(self) -> asyncio.Queue:
        q = asyncio.Queue(maxsize=self.maxsize)
        self.subscribers.add(q)
        for kind in ("health",):                 # a new tab should not wait 15 s for its first scores
            if kind in self.last:
                q.put_nowait(self.last[kind])
        return q

    def unsubscribe(self, q):
        self.subscribers.discard(q)

    def publish(self, kind: str, data: dict) -> dict:
        ev = {"id": next(self.seq), "kind": kind, "ts": time.time(), "data": data}
        self.last[kind] = ev
        for q in list(self.subscribers):
            if q.full():
                try:
                    q.get_nowait()              # drop the oldest for this slow subscriber
                except asyncio.QueueEmpty:
                    pass
            q.put_nowait(ev)
        if self.on_publish and kind in KEPT:
            self.on_publish(ev)
        return ev


def alerts_from_webhook(payload: dict) -> list[dict]:
    """Alertmanager's webhook body -> one feed item per alert. Keeps what a human scans for."""
    out = []
    for a in payload.get("alerts", []) or []:
        lab, ann = a.get("labels", {}) or {}, a.get("annotations", {}) or {}
        out.append({"status": a.get("status", payload.get("status")), "alertname": lab.get("alertname"),
                    "service": lab.get("service"), "severity": lab.get("severity"),
                    "summary": ann.get("summary"), "startsAt": a.get("startsAt"),
                    "endsAt": a.get("endsAt") if a.get("status") == "resolved" else None,
                    "fingerprint": a.get("fingerprint")})
    return out
