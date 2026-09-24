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
  feed, runs, kb_feeding, settings   (Day 24) the feed kept for timelines; game-day runs; the
             Day 17 feeding decision per resolved incident; one-time settings.
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
-- Day 24 --------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS feed (          -- the live feed, kept: a run's timeline is read back from here
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    ts    REAL NOT NULL,
    kind  TEXT NOT NULL,
    data  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS feed_ts ON feed (ts);
CREATE TABLE IF NOT EXISTS runs (          -- game-day runs: a sealed schedule, executed server-side
    id          TEXT PRIMARY KEY,
    scenario    TEXT NOT NULL,
    title       TEXT,
    started_at  REAL NOT NULL,
    operator    TEXT NOT NULL,
    requested_by TEXT,
    token       TEXT,
    status      TEXT NOT NULL,             -- running | done | aborted
    steps       TEXT NOT NULL,             -- JSON: the plan, and what happened at each step
    revealed_at REAL,
    ended_at    REAL,
    reset_at    REAL
);
CREATE TABLE IF NOT EXISTS kb_feeding (    -- Day 17's rule as a record: every resolved incident feeds the KB, or says why not
    incident TEXT PRIMARY KEY,
    ts       REAL NOT NULL,
    ts_iso   TEXT NOT NULL,
    operator TEXT NOT NULL,
    decision TEXT NOT NULL,                -- updated | not_needed
    kb_id    TEXT,
    reason   TEXT
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
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

    # ------------------------------------------------------------------- feed --
    async def add_feed(self, ts: float, kind: str, data: dict):
        await self.conn.execute("INSERT INTO feed (ts, kind, data) VALUES (?,?,?)", (ts, kind, json.dumps(data, default=str)[:20000]))
        await self.conn.commit()

    async def feed_between(self, t0: float, t1: float, limit: int = 2000) -> list:
        async with self.conn.execute("SELECT ts, kind, data FROM feed WHERE ts >= ? AND ts <= ? ORDER BY ts LIMIT ?",
                                     (t0, t1, limit)) as cur:
            return [{"ts": r["ts"], "kind": r["kind"], "data": json.loads(r["data"])} for r in await cur.fetchall()]

    async def prune_feed(self, days: float = 30):
        await self.conn.execute("DELETE FROM feed WHERE ts < ?", (time.time() - days * 86400,))
        await self.conn.commit()

    # ------------------------------------------------------------------- runs --
    async def save_run(self, run: dict):
        await self.conn.execute(
            "INSERT INTO runs (id, scenario, title, started_at, operator, requested_by, token, status, steps, revealed_at, ended_at, reset_at) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET status=excluded.status, steps=excluded.steps, "
            "revealed_at=excluded.revealed_at, ended_at=excluded.ended_at, reset_at=excluded.reset_at",
            (run["id"], run["scenario"], run.get("title"), run["started_at"], run["operator"], run.get("requested_by"),
             run.get("token"), run["status"], json.dumps(run["steps"], default=str), run.get("revealed_at"),
             run.get("ended_at"), run.get("reset_at")))
        await self.conn.commit()

    @staticmethod
    def _run(r) -> dict:
        d = dict(r)
        d["steps"] = json.loads(d["steps"])
        return d

    async def run(self, run_id: str):
        async with self.conn.execute("SELECT * FROM runs WHERE id = ?", (run_id,)) as cur:
            r = await cur.fetchone()
        return self._run(r) if r else None

    async def runs(self, limit: int = 50, status: str | None = None) -> list:
        q, args = "SELECT * FROM runs", []
        if status:
            q += " WHERE status = ?"; args.append(status)
        q += " ORDER BY started_at DESC LIMIT ?"; args.append(int(limit))
        async with self.conn.execute(q, args) as cur:
            return [self._run(r) for r in await cur.fetchall()]

    # ------------------------------------------------------------- kb feeding --
    async def set_kb_feeding(self, *, incident, operator, decision, kb_id=None, reason=None) -> dict:
        ts = time.time()
        await self.conn.execute(
            "INSERT INTO kb_feeding (incident, ts, ts_iso, operator, decision, kb_id, reason) VALUES (?,?,?,?,?,?,?) "
            "ON CONFLICT(incident) DO UPDATE SET ts=excluded.ts, ts_iso=excluded.ts_iso, operator=excluded.operator, "
            "decision=excluded.decision, kb_id=excluded.kb_id, reason=excluded.reason",
            (incident, ts, _iso(ts), operator, decision, kb_id, reason))
        await self.conn.commit()
        return {"incident": incident, "ts_iso": _iso(ts), "operator": operator, "decision": decision, "kb_id": kb_id, "reason": reason}

    async def kb_feeding(self) -> dict:
        async with self.conn.execute("SELECT * FROM kb_feeding") as cur:
            return {r["incident"]: dict(r) for r in await cur.fetchall()}

    # --------------------------------------------------------------- settings --
    async def setting(self, key: str, default: str | None = None, *, store_default: bool = False):
        async with self.conn.execute("SELECT value FROM settings WHERE key = ?", (key,)) as cur:
            r = await cur.fetchone()
        if r:
            return r["value"]
        if store_default and default is not None:
            await self.conn.execute("INSERT INTO settings (key, value) VALUES (?,?)", (key, default))
            await self.conn.commit()
        return default
