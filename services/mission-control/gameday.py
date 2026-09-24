"""
gameday.py — Day 24 Step 1: the Game Day console's engine.

Scenarios are gameday/*.yaml (mounted from ConfigMap `gameday`, scripts/240-gameday.sh): a title, a
sealed summary, and steps {at_seconds, action, params, note}. Only `set_fault` may be a step — a
scenario breaks things the way a human would, through the same catalog entry and its validator.

Run sealed (catalog action run_scenario, tier 2: ONE human approval for the whole schedule):
  * the schedule runs HERE, server-side — closing the browser does not stop it, and a restart of
    this pod resumes it (steps are persisted with their planned times; one that came due while we
    were down fires at once and says so);
  * the steps stay hidden until Retro: the API returns "sealed", each injection is audited as a
    sealed row (run + step number, the approval token that authorised it — never the knob), and its
    Grafana annotation says "step N (sealed)". The real rows are appended at Retro (the audit log is
    append-only; nothing is rewritten) and the annotations are PATCHed with the real text;
  * Reset all (reset_faults, tier 1) aborts any run first, so a late step cannot re-break the platform.

Grafana annotation tags are ["gameday", <run id>] and NEVER a service name: the bot's recent_deploys
collector reads annotations by service tag, and a game-day marker there would hand the answer to
the hypothesis (Eval 3-leak, Day 10). tests/test_gameday.py holds that line.

Retro builds gameday/run-<ts>.md: what was injected and when, the timeline from the kept feed
(alerts, incidents, approvals, actions), the incidents in the window with MTTD measured from the
injection that caused them, and the questions the scribe answers. scripts/245-gameday-run.sh saves it
into the repo.
"""

import asyncio
import glob
import os
import random
import re
import time

import yaml

import actions
import config

STEP_ACTIONS = {"set_fault"}
MAX_SCENARIO_S = 3 * 3600
# A fault on this target shows up as incidents on these services (egift calls activation).
AFFECTS = {"activation": {"activation", "egift"}, "egift": {"egift"}, "settlement": {"settlement"},
           "loadgen-activation": {"activation"}, "loadgen-egift": {"egift"}}


def _iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)) if ts else None


# ---------------------------------------------------------------- scenarios --
def load_scenarios(directory: str | None = None) -> dict:
    """{id: scenario} for every valid file, plus {"_errors": {file: why}} for the rest — a broken
    scenario is shown as broken, never silently skipped."""
    out, errors = {}, {}
    for path in sorted(glob.glob(os.path.join(directory or config.GAMEDAY_DIR, "*.yaml"))):
        name = os.path.basename(path)
        try:
            with open(path) as f:
                doc = yaml.safe_load(f) or {}
            out[doc_id(doc, name)] = validate_scenario(doc, name)
        except (ValueError, KeyError, TypeError, yaml.YAMLError, actions.ParamError) as e:
            errors[name] = str(e)[:300]
    if errors:
        out["_errors"] = errors
    return out


def doc_id(doc, name):
    sid = str(doc.get("id") or name.rsplit(".", 1)[0])
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,39}", sid):
        raise ValueError(f"id {sid!r}: lowercase letters, digits and dashes")
    return sid


def validate_scenario(doc: dict, name: str) -> dict:
    steps = doc.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ValueError("steps: a non-empty list")
    clean = []
    for i, st in enumerate(steps, 1):
        if not isinstance(st, dict):
            raise ValueError(f"step {i}: a mapping")
        if st.get("action") not in STEP_ACTIONS:
            raise ValueError(f"step {i}: action must be one of {sorted(STEP_ACTIONS)}")
        at, jit = int(st.get("at_seconds", 0)), int(st.get("jitter_seconds", 0))
        if not 0 <= at <= MAX_SCENARIO_S or not 0 <= jit <= 600:
            raise ValueError(f"step {i}: at_seconds 0-{MAX_SCENARIO_S}, jitter_seconds 0-600")
        params = actions.validate(st["action"], {k: str(v) for k, v in (st.get("params") or {}).items()})
        clean.append({"n": i, "at_seconds": at, "jitter_seconds": jit, "action": st["action"], "params": params,
                      "note": str(st.get("note") or "")[:500]})
    return {"id": doc_id(doc, name), "file": name, "title": str(doc.get("title") or name)[:120],
            "summary": str(doc.get("summary") or "")[:500], "steps": clean}


def public_scenario(sc: dict) -> dict:
    """What the console shows before a run: never the steps."""
    return {"id": sc["id"], "title": sc["title"], "summary": sc["summary"], "file": sc["file"]}


# ---------------------------------------------------------------- the runner --
class Runner:
    def __init__(self, db, get_http, audit, publish, scenarios=load_scenarios):
        self.db, self.get_http, self.audit, self.publish = db, get_http, audit, publish
        self.scenarios = scenarios
        self.tasks: dict[str, asyncio.Task] = {}

    # --- Grafana: sealed markers, revealed at Retro ------------------------------------------
    async def annotate(self, run_id: str, text: str, at: float):
        if not config.GRAFANA_WRITE_TOKEN or config.DRY_RUN:
            return None
        try:
            r = await self.get_http().post(f"{config.GRAFANA_URL}/api/annotations",
                                           json={"time": int(at * 1000), "tags": ["gameday", run_id], "text": text},
                                           headers={"Authorization": f"Bearer {config.GRAFANA_WRITE_TOKEN}"}, timeout=5)
            return r.json().get("id") if r.status_code == 200 else None
        except Exception:  # noqa: BLE001 — a missing marker must never stop a game day
            return None

    async def reannotate(self, ann_id, text: str) -> bool:
        if not ann_id or not config.GRAFANA_WRITE_TOKEN or config.DRY_RUN:
            return False
        try:
            r = await self.get_http().patch(f"{config.GRAFANA_URL}/api/annotations/{ann_id}", json={"text": text},
                                            headers={"Authorization": f"Bearer {config.GRAFANA_WRITE_TOKEN}"}, timeout=5)
            return r.status_code == 200
        except Exception:  # noqa: BLE001
            return False

    # --- lifecycle -----------------------------------------------------------------------------
    async def start(self, scenario_id: str, operator: str, token: str | None = None):
        sc = self.scenarios().get(scenario_id)
        if not sc or scenario_id.startswith("_"):
            return False, f"no scenario {scenario_id!r}"
        live = await self.sealed_run()
        if live:
            return False, f"refused: {live['id']} is still running (sealed) — Retro or Reset all first"
        now = time.time()
        run_id = time.strftime("run-%Y%m%dT%H%M%SZ", time.gmtime(now))
        steps = [{**st, "due_at": now + st["at_seconds"] + (random.randint(0, st["jitter_seconds"]) if st["jitter_seconds"] else 0),
                  "state": "pending"} for st in sc["steps"]]
        run = {"id": run_id, "scenario": sc["id"], "title": sc["title"], "started_at": now, "operator": operator,
               "token": token, "status": "running", "steps": steps}
        await self.db.save_run(run)
        ann = await self.annotate(run_id, f"game day {run_id} started ({sc['id']}, sealed)", now)
        run["steps"][0]["start_annotation"] = ann       # kept with the plan; patched at retro
        await self.db.save_run(run)
        self.publish("gameday", {"event": "started", "run": run_id, "scenario": sc["id"], "by": operator})
        self._spawn(run)
        return True, f"{run_id} started — {sc['id']} is sealed until Retro"

    async def sealed_run(self):
        """The run that keeps the console sealed: not revealed, not reset, not aborted — whether its
        schedule is still pending ("running") or has fired its last step ("done")."""
        for r in await self.db.runs(limit=20):
            if r["status"] in ("running", "done") and not r.get("revealed_at") and not r.get("reset_at"):
                return r
        return None

    def _spawn(self, run):
        self.tasks[run["id"]] = asyncio.create_task(self._run(run["id"]))

    async def resume(self):
        """After a restart: keep going. A step that came due while we were down fires now, late, and
        its record says how late — a game day interrupted by a deploy is still a game day."""
        for run in await self.db.runs(status="running"):
            if run["id"] not in self.tasks:
                self._spawn(run)

    async def _run(self, run_id: str):
        try:
            while True:
                run = await self.db.run(run_id)
                if not run or run["status"] != "running":
                    return
                pending = [s for s in run["steps"] if s["state"] == "pending"]
                if not pending:
                    run["status"] = "done"
                    run["ended_at"] = time.time()
                    await self.db.save_run(run)
                    self.publish("gameday", {"event": "schedule_complete", "run": run_id, "sealed": not run.get("revealed_at")})
                    return
                nxt = min(pending, key=lambda s: s["due_at"])
                wait = nxt["due_at"] - time.time()
                if wait > 0:
                    await asyncio.sleep(min(wait, 30))          # re-read the run: an abort may have happened
                    continue
                await self._fire(run, nxt)
        except asyncio.CancelledError:
            raise
        finally:
            self.tasks.pop(run_id, None)

    async def _fire(self, run, step):
        a = actions.CATALOG[step["action"]]
        t = time.time()
        try:
            ok, detail = await a["execute"](self.get_http(), step["params"], run["operator"])
        except Exception as e:  # noqa: BLE001
            ok, detail = False, f"{type(e).__name__}: {e}"
        step.update(state="fired" if ok else "failed", fired_at=t, late_s=round(max(0.0, t - step["due_at"]), 1),
                    ok=ok, detail=str(detail)[:300])
        step["annotation"] = await self.annotate(run["id"], f"game day {run['id']}: step {step['n']} (sealed)", t)
        await self.db.save_run(run)
        # The sealed audit row: WHO authorised it (the run's approver and token), THAT a step fired,
        # and whether it worked — not what it was. The real row is appended at Retro.
        await self.audit(operator=run["operator"], action="scenario_step", params={"run": run["id"], "step": step["n"]},
                         tier=2, entrance="scenario", result="ok" if ok else "failed", token=run.get("token"),
                         detail="sealed until Retro" if ok else "sealed step FAILED to inject — see Retro")
        self.publish("gameday", {"event": "step", "run": run["id"], "step": step["n"], "ok": ok, "sealed": True})

    async def abort(self, operator: str, why: str, run_id: str | None = None) -> int:
        n = 0
        if why == "reset_faults":
            # A run whose schedule has finished is still SEALED (its faults are live) until Retro or a
            # reset: the reset ends it too, so the console's knob panel may show values again.
            for run in await self.db.runs(status="done"):
                if not run.get("reset_at"):
                    run["reset_at"] = time.time()
                    await self.db.save_run(run)
        for run in await self.db.runs(status="running"):
            if run_id and run["id"] != run_id:
                continue
            task = self.tasks.pop(run["id"], None)
            if task:
                task.cancel()
            for s in run["steps"]:
                if s["state"] == "pending":
                    s["state"] = "skipped"
            run["status"], run["ended_at"] = "aborted", time.time()
            if why == "reset_faults":
                run["reset_at"] = run["ended_at"]
            await self.db.save_run(run)
            await self.audit(operator=operator, action="scenario_abort", params={"run": run["id"]}, tier=1,
                             entrance="scenario", result="ok", detail=f"remaining steps skipped ({why})")
            self.publish("gameday", {"event": "aborted", "run": run["id"], "by": operator})
            n += 1
        return n

    async def retro(self, run_id: str, operator: str) -> dict:
        run = await self.db.run(run_id)
        if not run:
            raise KeyError(run_id)
        if run.get("revealed_at"):
            return run
        run["revealed_at"] = time.time()
        if run["status"] == "running":             # Retro while steps are still pending ends the run: once
            await self.abort(operator, "retro", run_id)   # you have seen the plan it is no longer a test
            run = await self.db.run(run_id)
            run["revealed_at"] = time.time()
        for s in run["steps"]:
            if s.get("state") in ("fired", "failed"):
                what = f"{s['params']['target']} {s['params']['knob']}={s['params']['value']}"
                s["revealed_annotation"] = await self.reannotate(
                    s.get("annotation"), f"game day {run_id} step {s['n']}: {what} — {s.get('note') or ''}".strip(" —"))
                await self.audit(operator=run["operator"], action=f"scenario_step:{s['action']}", params=s["params"],
                                 tier=2, entrance="scenario", result="ok" if s.get("ok") else "failed", token=run.get("token"),
                                 detail=f"revealed at Retro: {run_id} step {s['n']} fired {_iso(s.get('fired_at'))}"
                                        f" (+{round(s.get('fired_at', 0) - run['started_at'])} s) — {s.get('detail', '')}"[:500])
        start_ann = run["steps"][0].get("start_annotation") if run["steps"] else None
        await self.reannotate(start_ann, f"game day {run_id} started ({run['scenario']})")
        await self.db.save_run(run)
        await self.audit(operator=operator, action="gameday_retro", params={"run": run_id}, tier=1,
                         entrance="button", result="ok", detail=f"{run['scenario']}: {len(run['steps'])} step(s) revealed")
        self.publish("gameday", {"event": "revealed", "run": run_id, "by": operator})
        return run


def public_run(run: dict) -> dict:
    """A run as the console shows it. Sealed: that it exists, when it started and who approved it."""
    base = {"id": run["id"], "scenario": run["scenario"], "title": run.get("title"), "operator": run["operator"],
            "started_at_iso": _iso(run["started_at"]), "revealed_at_iso": _iso(run.get("revealed_at")),
            "reset_at_iso": _iso(run.get("reset_at")), "ended_at_iso": _iso(run.get("ended_at"))}
    if not run.get("revealed_at"):
        # "done" would say "nothing more will happen" — a hint. Until Retro a run is just sealed.
        return {**base, "status": "aborted" if run["status"] == "aborted" else "sealed", "sealed": True}
    return {**base, "status": run["status"], "sealed": False,
            "steps": [{k: s.get(k) for k in ("n", "at_seconds", "action", "params", "note", "state", "ok", "detail", "late_s")}
                      | {"fired_at_iso": _iso(s.get("fired_at")), "offset_s": round(s["fired_at"] - run["started_at"]) if s.get("fired_at") else None}
                      for s in run["steps"]]}


# ------------------------------------------------------------ the skeleton --
def injection_for(inc: dict, runs: list) -> dict | None:
    """The fault that caused this incident: the latest fired step, on a target that surfaces on the
    incident's service, before its first alert (and at most an hour before)."""
    first = inc.get("first_alert_at") or inc.get("opened_at")
    if not first:
        return None
    best = None
    for run in runs:
        for s in run.get("steps", []):
            if s.get("state") != "fired" or not s.get("fired_at"):
                continue
            if inc.get("service") not in AFFECTS.get(s["params"].get("target"), set()):
                continue
            if 0 <= first - s["fired_at"] <= 3600 and (best is None or s["fired_at"] > best["fired_at"]):
                best = {"run": run["id"], "step": s["n"], "fired_at": s["fired_at"], "target": s["params"]["target"],
                        "knob": s["params"]["knob"], "value": s["params"]["value"]}
    return best


def _clock(ts, t0):
    d = int(round(ts - t0))
    return f"{_iso(ts)[11:19]}  {'-' if d < 0 else '+'}{abs(d) // 60}m{abs(d) % 60:02d}s"


def _feed_line(ev: dict) -> str | None:
    k, d = ev["kind"], ev["data"]
    if k == "alert":
        return f"alert **{d.get('alertname')}** {d.get('status')} ({d.get('severity') or '-'}, {d.get('service') or '-'})"
    if k == "incident":
        return f"incident **{d.get('id')}** {d.get('event')} — {d.get('service')} {','.join(d.get('alerts') or [])}"
    if k == "approval":
        who = d.get("operator") or d.get("source") or ""
        return f"approval {d.get('event')}: {d.get('action')} {d.get('params') or ''} {('by ' + who) if who else ''}".strip()
    if k == "deploy":
        return f"{d.get('kind')}: {d.get('service')} — {d.get('text') or ''}"
    if k == "gameday":
        return None                                  # the steps are listed above, with what they were
    if k == "audit":
        a = d.get("action", "")
        if a.startswith("tool:") or a.startswith("scenario_step") or a in ("rate_answer", "rate_draft", "rate_report") or d.get("tier", 1) == 0:
            return None      # reads and grades are not the response; the steps are in the table above, at their real times
        return f"{d.get('operator')} · {a} {d.get('params') or ''} → {d.get('result')} ({d.get('entrance')})"
    return None


def skeleton(run: dict, feed: list, incidents: list, now: float | None = None) -> str:
    """gameday/run-<ts>.md — the scribe's draft. Facts from the record; the judgement is left blank."""
    t0 = run["started_at"]
    now = now or time.time()
    lines = [f"# Game day {run['id']} — {run['scenario']}: {run.get('title') or ''}".rstrip(": "), "",
             f"Run sealed from Mission Control, approved by **{run['operator']}**"
             f"{' (token `' + run['token'] + '`)' if run.get('token') else ''}. "
             f"Started {_iso(t0)}; Retro {_iso(run.get('revealed_at')) or '—'}; "
             f"reset {_iso(run.get('reset_at')) or 'not yet — Reset all ends every game day'}.", "",
             "## What was injected (revealed at Retro)", "",
             "| step | planned | fired (UTC) | offset | what | worked | note |", "|---|---|---|---|---|---|---|"]
    for s in run["steps"]:
        what = f"`{s['params']['target']} {s['params']['knob']}={s['params']['value']}`"
        fired = _iso(s.get("fired_at"))[11:19] if s.get("fired_at") else s.get("state", "-")
        off = f"+{round(s['fired_at'] - t0)} s" + (f" ({s['late_s']} s late)" if s.get("late_s", 0) > 5 else "") if s.get("fired_at") else "-"
        lines.append(f"| {s['n']} | +{s['at_seconds']} s | {fired} | {off} | {what} | "
                     f"{'yes' if s.get('ok') else ('no — ' + (s.get('detail') or '')[:60] if s.get('state') == 'failed' else '-')} | {s.get('note', '')} |")
    lines += ["", "## Incidents in the window", "",
              "| incident | service | alerts | first alert | caused by | MTTD | opened | resolved | duration |",
              "|---|---|---|---|---|---|---|---|---|"]
    for inc in incidents:
        inj = injection_for(inc, [run])
        mttd = f"{round(inc['first_alert_at'] - inj['fired_at'])} s" if inj and inc.get("first_alert_at") else "—"
        cause = f"step {inj['step']} ({inj['target']} {inj['knob']})" if inj else "— (not a scenario step)"
        lines.append(f"| {inc['id']} | {inc.get('service')} | {', '.join(inc.get('alerts') or [])} | "
                     f"{(inc.get('first_alert_at_iso') or '')[11:19]} | {cause} | **{mttd}** | "
                     f"{(inc.get('opened_at_iso') or '')[11:19]} | {(inc.get('resolved_at_iso') or 'open')[11:19] if inc.get('resolved_at_iso') else 'open'} | "
                     f"{inc.get('duration_min') if inc.get('duration_min') is not None else '—'} min |")
    if not incidents:
        lines.append("| — | | | | | | | | |")
    lines += ["", "## Timeline (Mission Control's event stream)", ""]
    for ev in feed:
        text = _feed_line(ev)
        if text:
            lines.append(f"- `{_clock(ev['ts'], t0)}` {text}")
    if not any(_feed_line(e) for e in feed):
        lines.append("- (nothing in the feed for this window)")
    lines += ["", "## For the retro — the human part", "",
              "- **Detected:** which fault was found first, how, and how long after it was injected (the MTTD column)?",
              "- **Missed or late:** anything injected that no alert, ticket or human caught?",
              "- **Diagnosis:** first correct cause on the record — whose, and when? Did the hypothesis get it?",
              "- **Terminal:** did anyone leave the browser? What for? (That is the Day 25 gap list.)",
              "- **KB:** for each incident — KB updated, or not needed because …",
              "- **Scribe's notes vs this timeline:** what does the record miss that the humans saw?", "",
              f"_Generated by Mission Control at {_iso(now)} from the run record and the kept feed._", ""]
    return "\n".join(lines)
