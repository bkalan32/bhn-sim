"""
db.py — Mission Control's own memory: the audit log and the tier-2 approval queue.

Two tables in DATA_DIR/mission-control.db (a PVC), through aiosqlite — the app is async end to
end, and aiosqlite serialises every statement on one connection thread, so a DELETE … RETURNING
is atomic without extra locking.

  audit      one row per action attempt, whatever the entrance: when, who (X-Operator), what
             (action id + params), tier, the approval token if there was one, the entrance
             (button | command | copilot | mcp | api), the result, and the first 500 chars of
             the detail. Append-only: nothing in this service updates or deletes a row.
  approvals  tier-2 requests waiting for a human: token, action, params, reason, who asked,
             from which entrance, created/expires (30 min). Single-use: approve and decline
             both remove the row in the statement that reads it (take()).

Deliberately NOT here: incidents (the bot owns them), remediator proposals (the remediator owns
them). Mission Control shows them; it does not keep a second copy that can disagree.
"""

import json
import os
import time

import aiosqlite

SCHEMA = """
CREATE TABLE IF NOT EXISTS audit (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ts             REAL NOT NULL,
    ts_iso         TEXT NOT NULL,
    operator       TEXT NOT NULL,
    action         TEXT NOT NULL,
    params         TEXT NOT NULL,
    tier           INTEGER NOT NULL,
    approval_token TEXT,
    entrance       TEXT NOT NULL,
    result         TEXT NOT NULL,
    detail         TEXT
);
CREATE INDEX IF NOT EXISTS audit_ts ON audit (ts DESC);
CREATE TABLE IF NOT EXISTS approvals (
    token      TEXT PRIMARY KEY,
    action     TEXT NOT NULL,
    params     TEXT NOT NULL,
    reason     TEXT,
    tier       INTEGER NOT NULL,
    entrance   TEXT NOT NULL,
    operator   TEXT NOT NULL,
    created_at REAL NOT NULL,
    expires_at REAL NOT NULL
);
"""

TTL_S = int(os.getenv("APPROVAL_TTL_S", "1800"))


def _iso(ts: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


class DB:
    def __init__(self, path: str):
        self.path = path
        self.conn = None

    async def open(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        self.conn = await aiosqlite.connect(self.path)
        self.conn.row_factory = aiosqlite.Row
        await self.conn.execute("PRAGMA journal_mode = WAL")
        await self.conn.execute("PRAGMA busy_timeout = 5000")
        await self.conn.executescript(SCHEMA)
        await self.conn.commit()

    async def close(self):
        if self.conn:
            await self.conn.close()

    # ------------------------------------------------------------------ audit --
    async def audit(self, *, operator, action, params, tier, entrance, result, detail="", token=None) -> dict:
        ts = time.time()
        row = {"ts": ts, "ts_iso": _iso(ts), "operator": operator, "action": action, "params": params,
               "tier": tier, "approval_token": token, "entrance": entrance, "result": result,
               "detail": (detail or "")[:500]}
        cur = await self.conn.execute(
            "INSERT INTO audit (ts, ts_iso, operator, action, params, tier, approval_token, entrance, result, detail) "
            "VALUES (?,?,?,?,?,?,?,?,?,?)",
            (ts, row["ts_iso"], operator, action, json.dumps(params, sort_keys=True), tier, token, entrance, result,
             row["detail"]))
        await self.conn.commit()
        row["id"] = cur.lastrowid
        return row

    async def audit_rows(self, limit=100, action=None) -> list:
        q, args = "SELECT * FROM audit", []
        if action:
            q += " WHERE action = ?"; args.append(action)
        q += " ORDER BY id DESC LIMIT ?"; args.append(int(limit))
        async with self.conn.execute(q, args) as cur:
            rows = await cur.fetchall()
        return [{**dict(r), "params": json.loads(r["params"])} for r in rows]

    # -------------------------------------------------------------- approvals --
    async def add_approval(self, *, token, action, params, reason, tier, entrance, operator) -> dict:
        now = time.time()
        await self.conn.execute(
            "INSERT INTO approvals (token, action, params, reason, tier, entrance, operator, created_at, expires_at) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (token, action, json.dumps(params, sort_keys=True), reason, tier, entrance, operator, now, now + TTL_S))
        await self.conn.commit()
        return {"token": token, "action": action, "params": params, "reason": reason, "tier": tier,
                "entrance": entrance, "operator": operator, "created_at_iso": _iso(now),
                "expires_at_iso": _iso(now + TTL_S), "source": "mission-control"}

    @staticmethod
    def _approval(r) -> dict:
        return {"token": r["token"], "action": r["action"], "params": json.loads(r["params"]), "reason": r["reason"],
                "tier": r["tier"], "entrance": r["entrance"], "operator": r["operator"],
                "created_at_iso": _iso(r["created_at"]), "expires_at_iso": _iso(r["expires_at"]),
                "source": "mission-control"}

    async def approvals(self) -> list:
        async with self.conn.execute("SELECT * FROM approvals WHERE expires_at > ? ORDER BY created_at DESC",
                                     (time.time(),)) as cur:
            return [self._approval(r) for r in await cur.fetchall()]

    async def take_approval(self, token: str):
        """Remove and return a live approval — at most once. None if unknown, expired or used."""
        async with self.conn.execute("DELETE FROM approvals WHERE token = ? AND expires_at > ? RETURNING *",
                                     (token, time.time())) as cur:
            rows = await cur.fetchall()
        await self.conn.commit()
        return self._approval(rows[0]) if rows else None

    async def expire_approvals(self) -> list:
        async with self.conn.execute("DELETE FROM approvals WHERE expires_at <= ? RETURNING *", (time.time(),)) as cur:
            rows = await cur.fetchall()
        await self.conn.commit()
        return [self._approval(r) for r in rows]
