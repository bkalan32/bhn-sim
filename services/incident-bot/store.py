"""
store.py — the incident record, in SQLite. Day 21, chore 1.

Days 8-20 kept one JSON file per incident in /data (a PVC). That was enough for a bot that
only ever needed "the open incident for this service" and "list everything", and it did
survive restarts and rollouts. It stops being enough on the day a second reader arrives:
Mission Control asks "open incidents since 10:00, newest first" several times a minute, and
a directory of files answers that by opening and parsing every file every time. The timeline
was also a list inside the document, so every note rewrote the whole record.

Two tables, one file (DATA_DIR/incidents.db), stdlib sqlite3 — no ORM for two tables:

  incidents  one row per incident. The columns anyone filters or sorts on are real columns
             (status, service, severity, opened_at, join_key); everything else — alerts,
             groups, context, drafts, ai_meta — is the `doc` JSON, exactly the dict the bot
             has always built, minus the timeline.
  timeline   one row per event, (incident_id, seq) primary key. APPEND-ONLY: save() inserts
             the events it has not seen and refuses a timeline that got shorter. A record
             whose history can be rewritten is not a record.

WAL mode + a busy timeout: readers (GET /incidents from Mission Control) do not block the
writer (the webhook), and a writer waits up to 5 s for another instead of failing.

What this does NOT fix, and the rebuild proved it (CORRECTIONS-REBUILD N1): on kind the PVC
lives inside the node's container. A database file on it dies with the node exactly like the
JSON files did. SQLite buys queries and transactions, not durability; the durable record of
an incident is still the write-up in git.
"""

import json
import os
import sqlite3
import threading

SCHEMA = """
CREATE TABLE IF NOT EXISTS incidents (
    id          TEXT PRIMARY KEY,
    status      TEXT NOT NULL,
    service     TEXT,
    severity    TEXT,
    join_key    TEXT,
    opened_at   REAL NOT NULL,
    resolved_at REAL,
    doc         TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS incidents_status_opened ON incidents (status, opened_at DESC);
CREATE INDEX IF NOT EXISTS incidents_join_open     ON incidents (join_key, status);
CREATE TABLE IF NOT EXISTS timeline (
    incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    ts          REAL NOT NULL,
    event       TEXT NOT NULL,
    data        TEXT NOT NULL,
    PRIMARY KEY (incident_id, seq)
);
"""

_local = threading.local()
_path = None


class AppendOnlyViolation(Exception):
    pass


def _conn() -> sqlite3.Connection:
    """One connection per thread: the bot writes from the request handlers AND from the
    background draft/enrich threads, and a sqlite3 connection must not cross threads."""
    c = getattr(_local, "conn", None)
    if c is None or getattr(_local, "path", None) != _path:
        c = sqlite3.connect(_path, timeout=5.0, isolation_level=None)   # autocommit; explicit BEGIN below
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA foreign_keys = ON")
        c.execute("PRAGMA busy_timeout = 5000")
        _local.conn, _local.path = c, _path
    return c


def init(data_dir: str) -> dict:
    """Open (or create) the database and import any Day 8-20 JSON records found beside it.
    Returns {"db": path, "imported": n}. Idempotent: an imported file is renamed *.json.imported."""
    global _path
    os.makedirs(data_dir, exist_ok=True)
    _path = os.path.join(data_dir, "incidents.db")
    c = _conn()
    c.execute("PRAGMA journal_mode = WAL")
    c.executescript(SCHEMA)
    imported = 0
    for name in sorted(os.listdir(data_dir)):
        if not name.endswith(".json") or not name.startswith("INC-"):
            continue
        p = os.path.join(data_dir, name)
        try:
            with open(p) as f:
                inc = json.load(f)
            if load(inc["id"]) is None:
                save(inc)
                imported += 1
            os.replace(p, p + ".imported")
        except Exception:  # noqa: BLE001 — a bad file stays where it is, for a human
            continue
    return {"db": _path, "imported": imported}


def _split(inc: dict):
    doc = {k: v for k, v in inc.items() if k != "timeline"}
    return doc, list(inc.get("timeline") or [])


def save(inc: dict) -> None:
    """Upsert the incident row and append any timeline events not stored yet — one transaction."""
    doc, tl = _split(inc)
    c = _conn()
    c.execute("BEGIN IMMEDIATE")
    try:
        c.execute(
            """INSERT INTO incidents (id, status, service, severity, join_key, opened_at, resolved_at, doc)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET status=excluded.status, service=excluded.service,
                 severity=excluded.severity, join_key=excluded.join_key, opened_at=excluded.opened_at,
                 resolved_at=excluded.resolved_at, doc=excluded.doc""",
            (doc["id"], doc.get("status", "open"), doc.get("service"), doc.get("severity"),
             doc.get("join_key"), doc.get("opened_at", 0), doc.get("resolved_at"),
             json.dumps(doc, separators=(",", ":"))))
        have = c.execute("SELECT COUNT(*) FROM timeline WHERE incident_id = ?", (doc["id"],)).fetchone()[0]
        if len(tl) < have:
            raise AppendOnlyViolation(f"{doc['id']}: timeline has {have} events stored, save() passed {len(tl)}")
        c.executemany(
            "INSERT INTO timeline (incident_id, seq, ts, event, data) VALUES (?, ?, ?, ?, ?)",
            [(doc["id"], i, ev.get("ts", 0), ev.get("event", "?"), json.dumps(ev, separators=(",", ":")))
             for i, ev in enumerate(tl) if i >= have])
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise


def load(iid: str):
    """The full record — doc plus timeline in order — or None."""
    c = _conn()
    row = c.execute("SELECT doc FROM incidents WHERE id = ?", (iid,)).fetchone()
    if row is None:
        return None
    inc = json.loads(row["doc"])
    inc["timeline"] = [json.loads(r["data"]) for r in
                       c.execute("SELECT data FROM timeline WHERE incident_id = ? ORDER BY seq", (iid,))]
    return inc


def summaries(status=None, since=None, limit=500) -> list:
    """Records WITHOUT their timelines, newest first. `since` is an epoch: opened at or after."""
    q, args = "SELECT doc FROM incidents", []
    where = []
    if status:
        where.append("status = ?"); args.append(status)
    if since is not None:
        where.append("opened_at >= ?"); args.append(float(since))
    if where:
        q += " WHERE " + " AND ".join(where)
    q += " ORDER BY opened_at DESC LIMIT ?"
    args.append(int(limit))
    return [json.loads(r["doc"]) for r in _conn().execute(q, args)]


def find_open(join_key: str):
    row = _conn().execute(
        "SELECT id FROM incidents WHERE join_key = ? AND status = 'open' ORDER BY opened_at DESC LIMIT 1",
        (join_key,)).fetchone()
    return load(row["id"]) if row else None


def count(status=None) -> int:
    if status:
        return _conn().execute("SELECT COUNT(*) FROM incidents WHERE status = ?", (status,)).fetchone()[0]
    return _conn().execute("SELECT COUNT(*) FROM incidents").fetchone()[0]


def delete(iid: str) -> bool:
    c = _conn()
    c.execute("BEGIN IMMEDIATE")
    try:
        c.execute("DELETE FROM timeline WHERE incident_id = ?", (iid,))
        n = c.execute("DELETE FROM incidents WHERE id = ?", (iid,)).rowcount
        c.execute("COMMIT")
    except Exception:
        c.execute("ROLLBACK")
        raise
    return n > 0


def ping() -> bool:
    """Readiness: can we write? A read-only or vanished volume must take the pod out of
    rotation so Alertmanager retries instead of dropping the webhook."""
    c = _conn()
    c.execute("BEGIN IMMEDIATE")
    c.execute("ROLLBACK")
    return True
