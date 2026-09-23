"""
state.py — what the remediator must not forget. Day 21, chore 2.

Days 12-20 kept tier-2 proposals and cooldowns in two dicts. The code said so ("a restart
forgets proposals; noted lab limitation"), and a restart is exactly what a deploy is. Two
failure modes, both on the safety path:

  * a proposal a human was about to approve vanished — the approve link on the ticket
    returned 404 and the incident carried a PROPOSED note for an action that no longer
    existed anywhere;
  * the cooldown vanished — a remediator restarted two minutes after acting would act
    again on the same still-firing alert, which is the loop the cooldown exists to stop.

Two tables in DATA_DIR/remediator.db (a PVC):

  pending   one row per tier-2 proposal: token, signature, incident, service, created_at,
            expires_at (created + TOKEN_TTL_S, 30 min), and the proposal document.
  cooldown  signature -> the epoch of the last executed or attempted action.

The property that matters most is on `take()`: **a token is used at most once**. Approve and
decline both call it, and it is a single `DELETE … WHERE token = ? AND expires_at > now
RETURNING doc` — the row is removed in the same statement that reads it, so two clicks, two
browser tabs, or a click racing the expiry sweep get one winner and one 404. (The PDF's
troubleshooting note: "Tier 2 approval succeeds twice: the token must be single-use and
deleted on approve or decline inside the same transaction. Test the double-click.")
"""

import json
import os
import sqlite3
import threading

SCHEMA = """
CREATE TABLE IF NOT EXISTS pending (
    token      TEXT PRIMARY KEY,
    signature  TEXT NOT NULL,
    incident   TEXT,
    service    TEXT,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    doc        TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS pending_expiry ON pending (expires_at);
CREATE TABLE IF NOT EXISTS cooldown (
    signature TEXT PRIMARY KEY,
    last_at   REAL NOT NULL
);
"""

_local = threading.local()
_path = None
_init_lock = threading.Lock()


def init(data_dir: str) -> str:
    global _path
    with _init_lock:
        os.makedirs(data_dir, exist_ok=True)
        _path = os.path.join(data_dir, "remediator.db")
        c = _conn()
        c.execute("PRAGMA journal_mode = WAL")
        c.executescript(SCHEMA)
    return _path


def ready() -> bool:
    return _path is not None


def _conn() -> sqlite3.Connection:
    c = getattr(_local, "conn", None)
    if c is None or getattr(_local, "path", None) != _path:
        c = sqlite3.connect(_path, timeout=5.0, isolation_level=None)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA busy_timeout = 5000")
        _local.conn, _local.path = c, _path
    return c


def _docs(rows):
    return [json.loads(r["doc"]) for r in rows]


# ------------------------------------------------------------------ pending --
def add_pending(p: dict) -> bool:
    """Store a proposal unless one for the same (signature, incident) is already waiting.
    Returns False for the duplicate. Check and insert are one transaction."""
    c = _conn()
    c.execute("BEGIN IMMEDIATE")
    try:
        dup = c.execute("SELECT 1 FROM pending WHERE signature = ? AND incident IS ? LIMIT 1",
                        (p["signature"], p.get("incident"))).fetchone()
        if dup:
            c.execute("ROLLBACK")
            return False
        c.execute("INSERT INTO pending (token, signature, incident, service, created_at, expires_at, doc) VALUES (?,?,?,?,?,?,?)",
                  (p["token"], p["signature"], p.get("incident"), p.get("service"), p["created_at"], p["expires_at"],
                   json.dumps(p, separators=(",", ":"))))
        c.execute("COMMIT")
        return True
    except Exception:
        c.execute("ROLLBACK")
        raise


def has_pending(signature: str, incident) -> bool:
    return _conn().execute("SELECT 1 FROM pending WHERE signature = ? AND incident IS ? LIMIT 1",
                           (signature, incident)).fetchone() is not None


def list_pending(now: float) -> list:
    return _docs(_conn().execute("SELECT doc FROM pending WHERE expires_at > ? ORDER BY created_at DESC", (now,)))


def take(token: str, now: float):
    """Remove and return a live proposal — at most once, ever. None if unknown, expired or used."""
    # fetchall(), never fetchone(): a RETURNING statement is only finished — and in autocommit
    # mode only committed — once its rows are exhausted. A half-read cursor holds the write lock.
    rows = _conn().execute("DELETE FROM pending WHERE token = ? AND expires_at > ? RETURNING doc", (token, now)).fetchall()
    return json.loads(rows[0]["doc"]) if rows else None


def expire(now: float) -> list:
    """Remove and return every proposal whose 30 minutes are up."""
    return _docs(_conn().execute("DELETE FROM pending WHERE expires_at <= ? RETURNING doc", (now,)).fetchall())


def withdraw(service: str) -> list:
    """The alerts for this service resolved: remove and return its proposals."""
    return _docs(_conn().execute("DELETE FROM pending WHERE service = ? RETURNING doc", (service,)).fetchall())


def count_pending(now: float) -> int:
    return _conn().execute("SELECT COUNT(*) FROM pending WHERE expires_at > ?", (now,)).fetchone()[0]


# ----------------------------------------------------------------- cooldown --
def mark_action(signature: str, ts: float) -> None:
    _conn().execute("INSERT INTO cooldown (signature, last_at) VALUES (?, ?) "
                    "ON CONFLICT(signature) DO UPDATE SET last_at = excluded.last_at", (signature, ts))


def last_action(signature: str) -> float:
    row = _conn().execute("SELECT last_at FROM cooldown WHERE signature = ?", (signature,)).fetchone()
    return row["last_at"] if row else 0.0


def ping() -> bool:
    c = _conn()
    c.execute("BEGIN IMMEDIATE")
    c.execute("ROLLBACK")
    return True
