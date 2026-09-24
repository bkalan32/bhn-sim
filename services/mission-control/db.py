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
  evals      (Day 22) a human's verdict on an AI draft — thumbs up/down from the incident page:
             incident, which draft, verdict, optional comment, who, when. The structured
             version of docs/ai-eval.md. Day 23: also on a copilot answer (turn_id).
  turns      (Day 23) every copilot answer: question, answer, the tool trail, model, tokens,
             cost — what a grade is a grade OF. The conversation itself lives in memory
             for 30 minutes (copilot.py); the record of what was said lives here.

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
CREATE TABLE IF NOT EXISTS evals (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         REAL NOT NULL,
    ts_iso     TEXT NOT NULL,
    operator   TEXT NOT NULL,
    incident   TEXT NOT NULL,
    draft      TEXT NOT NULL,
    verdict    TEXT NOT NULL,
    comment    TEXT,
    model      TEXT
);
CREATE INDEX IF NOT EXISTS evals_incident ON evals (incident);
CREATE TABLE IF NOT EXISTS turns (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          REAL NOT NULL,
    ts_iso      TEXT NOT NULL,
    conversation TEXT NOT NULL,
    incident    TEXT,
    operator    TEXT NOT NULL,
    entrance    TEXT NOT NULL,
    question    TEXT NOT NULL,
    answer      TEXT NOT NULL,
    note        TEXT,
    trail       TEXT NOT NULL,
    model       TEXT,
    tokens_in   INTEGER,
    tokens_out  INTEGER,
    cost_usd    REAL,
    ms          INTEGER
);
"""
MIGRATIONS = [("evals", "turn_id", "INTEGER")]      # Day 23: a grade can be of a copilot answer

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
        for table, col, typ in MIGRATIONS:              # a PVC written by an older image gains the column
            async with self.conn.execute(f"PRAGMA table_info({table})") as cur:
                cols = {r[1] for r in await cur.fetchall()}
            if col not in cols:
                await self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {typ}")
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

    # ------------------------------------------------------------------ evals --
    async def add_eval(self, *, operator, incident, draft, verdict, comment="", model=None, turn_id=None) -> dict:
        ts = time.time()
        cur = await self.conn.execute(
            "INSERT INTO evals (ts, ts_iso, operator, incident, draft, verdict, comment, model, turn_id) VALUES (?,?,?,?,?,?,?,?,?)",
            (ts, _iso(ts), operator, incident, draft, verdict, (comment or "")[:1000], model, turn_id))
        await self.conn.commit()
        return {"id": cur.lastrowid, "ts_iso": _iso(ts), "operator": operator, "incident": incident, "draft": draft,
                "verdict": verdict, "comment": (comment or "")[:1000], "model": model, "turn_id": turn_id}

    async def evals(self, incident=None, limit=200) -> list:
        """Grades, newest first — with the copilot answer each one is about, when it is about one."""
        q = ("SELECT e.*, t.question AS question, t.answer AS answer, t.trail AS trail, t.tokens_in AS tokens_in, "
             "t.tokens_out AS tokens_out, t.cost_usd AS cost_usd, t.entrance AS turn_entrance "
             "FROM evals e LEFT JOIN turns t ON t.id = e.turn_id")
        args = []
        if incident:
            q += " WHERE e.incident = ?"; args.append(incident)
        q += " ORDER BY e.id DESC LIMIT ?"; args.append(int(limit))
        async with self.conn.execute(q, args) as cur:
            rows = [dict(r) for r in await cur.fetchall()]
        for r in rows:
            r["trail"] = json.loads(r["trail"]) if r.get("trail") else None
        return rows

    # ------------------------------------------------------------------ turns --
    async def add_turn(self, *, conversation, incident, operator, entrance, rec: dict) -> int:
        ts = time.time()
        trail = [{k: v for k, v in t.items() if k != "result"} for t in rec.get("trail", [])]
        cur = await self.conn.execute(
            "INSERT INTO turns (ts, ts_iso, conversation, incident, operator, entrance, question, answer, note, trail, "
            "model, tokens_in, tokens_out, cost_usd, ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (ts, _iso(ts), conversation, incident, operator, entrance, rec["question"][:4000], rec["answer"][:20000],
             rec.get("note"), json.dumps(trail, default=str)[:60000], rec.get("model"), rec.get("tokens_in"),
             rec.get("tokens_out"), rec.get("cost_usd"), rec.get("ms")))
        await self.conn.commit()
        return cur.lastrowid

    async def turn(self, turn_id: int):
        async with self.conn.execute("SELECT * FROM turns WHERE id = ?", (int(turn_id),)) as cur:
            r = await cur.fetchone()
        return dict(r) if r else None
