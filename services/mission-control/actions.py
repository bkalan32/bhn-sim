"""
actions.py — THE action catalog. Day 21, Step 3.

One design rule (docs/mission-control.md, first line): one catalog, three entrances. A button,
a slash command and a copilot proposal all name an entry here by id; the entry says what tier
it is, what parameters it takes and how they are validated, and the ONE executor that runs it.
There is no second way to roll back activation. If an entrance could do something this file
does not list, it would be a bypass.

Tiers (the Day 12 policy, now for humans too):
  1  auto     one click: validated, executed, audited, a toast
  2  approve  validated NOW (a bad parameter never waits 30 min to fail), stored as a pending
              approval with a single-use token; a human with a second click executes it
  3  human    not in the catalog at all — no button can exist; the UI says "escalate"

Executors run kubectl as an argv list (never a shell) and only the verbs in KUBECTL_VERBS; the
ServiceAccount's Role (k8s/mission-control.yaml) is the real boundary — the allow-list here is
the second one, so a bug in this file still meets RBAC, and RBAC gaps still meet this file.
DRY_RUN=true makes every executor return what it WOULD have done.
"""

import asyncio
import datetime as dt
import json
import re
import time

import config

SERVICES = ("activation", "egift", "incident-bot", "settlement", "remediator", "loadgen")
ROLLBACKABLE = ("activation", "egift", "incident-bot", "remediator", "loadgen")   # Deployments with history

# The fault knobs (Days 2-5 + Day 21's traffic multiplier). target -> knob -> validator.
# `container` is set for loadgen, whose two targets are containers of one Deployment.
KNOBS = {
    "activation": {"kind": "deployment", "name": "activation", "container": None, "knobs": {
        "ERROR_RATE": ("float", 0.0, 1.0, "0.02"), "BASE_LATENCY_MS": ("int", 0, 5000, "80"),
        "FRAUD_SVC_DOWN": ("bool", None, None, "false")}},
    "egift": {"kind": "deployment", "name": "egift", "container": None, "knobs": {
        "DELIVERY_DELAY_MS": ("int", 0, 10000, "40"), "EMAIL_FAIL_RATE": ("float", 0.0, 1.0, "0.01")}},
    "settlement": {"kind": "cronjob", "name": "settlement", "container": None, "knobs": {
        "SETTLEMENT_FAIL_MODE": ("enum", ("none", "crash", "silent"), None, "none")}},
    "loadgen-activation": {"kind": "deployment", "name": "loadgen", "container": "activation", "knobs": {
        "RATE_MULTIPLIER": ("float", 0.0, 10.0, "1")}},
    "loadgen-egift": {"kind": "deployment", "name": "loadgen", "container": "egift", "knobs": {
        "RATE_MULTIPLIER": ("float", 0.0, 10.0, "1")}},
}

KUBECTL_VERBS = {("create", "job"), ("delete", "pod"), ("rollout", "undo"), ("scale", "deployment"),
                 ("set", "env"), ("get", "pod"), ("get", "configmap")}


class ParamError(ValueError):
    pass


# ------------------------------------------------------------------ validation --
def _str(v, name, pattern=r"^[A-Za-z0-9_.:/ -]{1,200}$"):
    if not isinstance(v, str) or not re.fullmatch(pattern, v):
        raise ParamError(f"{name}: expected text matching {pattern}")
    return v


def _choice(v, name, options):
    if v not in options:
        raise ParamError(f"{name}: one of {', '.join(options)}")
    return v


def _int(v, name, lo, hi):
    try:
        i = int(v)
    except (TypeError, ValueError):
        raise ParamError(f"{name}: an integer {lo}-{hi}")
    if not lo <= i <= hi or str(v).strip() not in (str(i), f"{i}.0"):
        raise ParamError(f"{name}: an integer {lo}-{hi}")
    return i


def knob_value(target, knob, value) -> str:
    """Validate one fault knob and return the string that goes into the env var."""
    t = KNOBS.get(target)
    if not t:
        raise ParamError(f"target: one of {', '.join(KNOBS)}")
    spec = t["knobs"].get(knob)
    if not spec:
        raise ParamError(f"knob: for {target}, one of {', '.join(t['knobs'])}")
    kind, lo, hi, _ = spec
    s = str(value).strip().lower() if value is not None else ""
    if kind == "bool":
        if s not in ("true", "false"):
            raise ParamError(f"{knob}: true or false")
        return s
    if kind == "enum":
        return _choice(s, knob, lo)
    try:
        num = float(s) if kind == "float" else int(s)
    except ValueError:
        raise ParamError(f"{knob}: a number {lo}-{hi}")
    if not lo <= num <= hi:
        raise ParamError(f"{knob}: between {lo} and {hi}")
    return s


def validate(action_id: str, params: dict) -> dict:
    """Return the cleaned parameters for this action, or raise ParamError. Unknown keys refused."""
    a = CATALOG.get(action_id)
    if not a:
        raise KeyError(action_id)
    params = dict(params or {})
    allowed = set(a["params"])
    extra = set(params) - allowed
    if extra:
        raise ParamError(f"unknown parameter(s): {', '.join(sorted(extra))}")
    return a["validate"](params)


def _v_none(p):
    return {}


def _v_note(p):
    text = p.get("text")
    if not isinstance(text, str) or not text.strip() or len(text) > 2000:
        raise ParamError("text: 1-2000 characters")
    return {"incident": _str(p.get("incident"), "incident", r"^[A-Za-z0-9_.-]{1,80}$"), "text": text.strip()}


def _v_pod(p):
    return {"pod": _str(p.get("pod"), "pod", r"^[a-z0-9]([-a-z0-9]{0,251}[a-z0-9])?$")}


def _v_rollback(p):
    return {"service": _choice(p.get("service"), "service", ROLLBACKABLE)}


def _v_scale(p):
    return {"service": _choice(p.get("service"), "service", ROLLBACKABLE), "replicas": _int(p.get("replicas"), "replicas", 0, 4)}


def _v_deploy(p):
    skip = p.get("skip_verify", False)
    if skip not in (True, False, "true", "false"):
        raise ParamError("skip_verify: true or false")
    cause = p.get("change_cause") or "deployed from mission control"
    return {"service": _choice(p.get("service"), "service", SERVICES),
            "change_cause": _str(cause, "change_cause", r"^[^\n\r'\"`$\\]{1,200}$"),
            "skip_verify": skip in (True, "true")}


def _v_silence(p):
    return {"alertname": _str(p.get("alertname"), "alertname", r"^[A-Za-z0-9_:]{1,100}$"),
            "minutes": _int(p.get("minutes", 30), "minutes", 5, 240),
            "service": _str(p["service"], "service", r"^[a-z0-9-]{1,40}$") if p.get("service") else None}


def _v_fault(p):
    target, knob = p.get("target"), p.get("knob")
    return {"target": target, "knob": knob, "value": knob_value(target, knob, p.get("value"))}


# --------------------------------------------------------------------- executors --
async def kubectl(*args, input_json=None) -> tuple[bool, str]:
    argv = [a for a in args if a is not None]
    verb = (argv[0], argv[1].split("/")[0]) if len(argv) > 1 else (argv[0], "")
    if verb not in KUBECTL_VERBS:
        return False, f"refused: kubectl {verb[0]} {verb[1]} is not on the allow-list"
    full = [config.KUBECTL, "-n", config.NAMESPACE, *argv]
    if config.DRY_RUN:
        return True, "DRY_RUN would run: " + " ".join(full)
    proc = await asyncio.create_subprocess_exec(*full, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=90)
    except asyncio.TimeoutError:
        proc.kill()
        return False, "kubectl timed out after 90 s"
    return proc.returncode == 0, out.decode(errors="replace").strip()[-1500:]


async def _jenkins(http, job, params=None) -> tuple[bool, str]:
    if not (config.JENKINS_URL and config.JENKINS_USER and config.JENKINS_TOKEN):
        return False, "Jenkins not configured (secret/mission-control-config: JENKINS_URL/USER/TOKEN — scripts/210-mc-config.sh)"
    path = f"/job/{job}/buildWithParameters" if params else f"/job/{job}/build"
    if config.DRY_RUN:
        return True, f"DRY_RUN would POST {config.JENKINS_URL}{path} {params or ''}"
    r = await http.post(config.JENKINS_URL + path, params=params, auth=(config.JENKINS_USER, config.JENKINS_TOKEN), timeout=10)
    if r.status_code in (200, 201):
        return True, f"queued {job}: {r.headers.get('location', '')}"
    return False, f"Jenkins {r.status_code}: {r.text[:200]}"


async def x_note(http, p, operator):
    if config.DRY_RUN:
        return True, f"DRY_RUN would note {p['incident']}"
    r = await http.post(f"{config.BOT_URL}/incidents/{p['incident']}/note", json={"text": p["text"], "author": operator}, timeout=5)
    return r.status_code == 200, r.text[:300]


async def x_rerun_settlement(http, p, operator):
    return await kubectl("create", "job", f"settlement-manual-{int(time.time())}", "--from=cronjob/settlement")


async def x_delete_pod(http, p, operator):
    ok, out = await kubectl("get", "pod", p["pod"], "-o", "json")
    if config.DRY_RUN:
        return True, f"DRY_RUN would check {p['pod']} is in CrashLoopBackOff, then delete it"
    if not ok:
        return False, out
    try:
        st = json.loads(out)["status"].get("containerStatuses", [])
        waiting = [c.get("state", {}).get("waiting", {}).get("reason") for c in st]
    except Exception as e:  # noqa: BLE001
        return False, f"could not read the pod: {e}"
    if "CrashLoopBackOff" not in waiting:
        return False, f"refused: {p['pod']} is not in CrashLoopBackOff ({waiting or 'no waiting state'}) — delete is for crash loops only"
    return await kubectl("delete", "pod", p["pod"], "--wait=false")


async def x_drift(http, p, operator):
    return await _jenkins(http, "infra-drift-check")


async def x_report(http, p, operator):
    return await _jenkins(http, "daily-ops-report")


async def x_rollback(http, p, operator):
    return await kubectl("rollout", "undo", f"deployment/{p['service']}")


async def x_scale(http, p, operator):
    return await kubectl("scale", f"deployment/{p['service']}", f"--replicas={p['replicas']}")


async def x_deploy(http, p, operator):
    return await _jenkins(http, "deploy-service", {"SERVICE": p["service"],
                                                   "CHANGE_CAUSE": f"{p['change_cause']} (by {operator}, mission control)",
                                                   "SKIP_VERIFY": "true" if p["skip_verify"] else "false"})


async def x_silence(http, p, operator):
    now = dt.datetime.now(dt.timezone.utc)
    matchers = [{"name": "alertname", "value": p["alertname"], "isRegex": False, "isEqual": True}]
    if p.get("service"):
        matchers.append({"name": "service", "value": p["service"], "isRegex": False, "isEqual": True})
    body = {"matchers": matchers, "startsAt": now.isoformat(), "endsAt": (now + dt.timedelta(minutes=p["minutes"])).isoformat(),
            "createdBy": operator, "comment": f"mission control, {p['minutes']} min"}
    if config.DRY_RUN:
        return True, f"DRY_RUN would create silence {json.dumps(matchers)} for {p['minutes']} min"
    r = await http.post(f"{config.AM_URL}/api/v2/silences", json=body, timeout=5)
    return r.status_code == 200, r.text[:300]


async def x_set_fault(http, p, operator):
    t = KNOBS[p["target"]]
    return await kubectl("set", "env", f"{t['kind']}/{t['name']}", *(["-c", t["container"]] if t["container"] else []),
                         f"{p['knob']}={p['value']}")


def _t(tier, title, params, validate, execute, blast, rationale):
    return {"tier": tier, "title": title, "params": params, "validate": validate, "execute": execute,
            "blast_radius": blast, "rationale": rationale}


CATALOG = {
    # tier 1 — one click, audited
    "note": _t(1, "Add a note to an incident", ("incident", "text"), _v_note, x_note,
               "one timeline event", "The scribe's job: the record is what every draft and review is written from."),
    "rerun_settlement": _t(1, "Re-run settlement now", (), _v_none, x_rerun_settlement,
                           "one Job from the CronJob's current template", "Day 12 tier 1: idempotent batch, re-running is the known fix."),
    "delete_crashlooping_pod": _t(1, "Delete a crash-looping pod", ("pod",), _v_pod, x_delete_pod,
                                  "one pod; its Deployment replaces it", "Only if the pod IS in CrashLoopBackOff — checked first."),
    "run_drift_check": _t(1, "Run the infra drift check", (), _v_none, x_drift,
                          "read-only: terraform plan in Jenkins", "Day 13: is the platform what the code says?"),
    "generate_report": _t(1, "Generate the daily ops report now", (), _v_none, x_report,
                          "read-only: a Jenkins job writes a report", "Day 18: the brief, on demand."),
    # tier 2 — a human approves
    "rollback": _t(2, "Roll back a Deployment one revision", ("service",), _v_rollback, x_rollback,
                   "every pod of that service is replaced", "Day 6 / Day 12: the known fix for a bad release."),
    "scale": _t(2, "Scale a Deployment (0-4)", ("service", "replicas"), _v_scale, x_scale,
                "0 replicas = that service is down", "Capacity, or stopping a runaway consumer."),
    "deploy": _t(2, "Deploy a service through the pipeline", ("service", "change_cause", "skip_verify"), _v_deploy, x_deploy,
                 "a new build of that service; skip_verify removes the auto-rollback", "The only door for a service change (Day 6)."),
    "silence_alert": _t(2, "Silence an alert (5-240 min)", ("alertname", "minutes", "service"), _v_silence, x_silence,
                        "matching alerts stop notifying — including the bot", "Planned maintenance (CORRECTIONS-REBUILD B9)."),
    "set_fault": _t(2, "Set a fault knob", ("target", "knob", "value"), _v_fault, x_set_fault,
                    "the target restarts with the new value; a fault is a production change", "Game days (Day 24): breaking on purpose has the same ceremony as fixing."),
}


def public_catalog() -> list:
    """What GET /api/actions returns — the catalog without the functions."""
    out = []
    for aid, a in CATALOG.items():
        item = {"id": aid, "tier": a["tier"], "title": a["title"], "params": list(a["params"]),
                "blast_radius": a["blast_radius"], "rationale": a["rationale"]}
        if aid == "set_fault":
            item["knobs"] = {t: {k: {"type": s[0], "range": [s[1], s[2]] if s[0] in ("int", "float") else s[1], "baseline": s[3]}
                                 for k, s in v["knobs"].items()} for t, v in KNOBS.items()}
        if aid in ("rollback", "scale"):
            item["services"] = list(ROLLBACKABLE)
        if aid == "deploy":
            item["services"] = list(SERVICES)
        out.append(item)
    return out
