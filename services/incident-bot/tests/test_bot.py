"""
Unit tests for the incident bot. Same pattern as the activation tests: the real server
in a subprocess, plain urllib, no TestClient/httpx dependency.

The payloads below are the shape Alertmanager actually sends (webhook v4). If you ever
wonder what a field is called, this file is the reference.
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.dirname(HERE)


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start(extra_env):
    port = _free_port()
    data = tempfile.mkdtemp(prefix="incbot-")
    env = {**os.environ, "DATA_DIR": data, "INCIDENT_JOIN": "service",
           # Day 10: collectors point at closed ports so enrichment degrades in milliseconds
           "PROM_URL": "http://127.0.0.1:9", "GRAFANA_URL": "http://127.0.0.1:9", "ENRICH_TIMEOUT_S": "1",
           **extra_env}
    env.pop("ANTHROPIC_API_KEY", None)          # tests never touch the network
    env.pop("SPLUNK_URL", None)
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1",
         "--port", str(port), "--log-level", "warning"],
        cwd=APP_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    url = f"http://127.0.0.1:{port}"
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"{url}/healthz", timeout=1)
            break
        except Exception:
            if proc.poll() is not None:
                raise RuntimeError("server died:\n" + proc.stdout.read().decode())
            time.sleep(0.3)
    else:
        proc.kill()
        raise RuntimeError("server never became ready:\n" + proc.stdout.read().decode()[-2000:])
    return proc, url


def _stop(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


@pytest.fixture(scope="session")
def base_url():
    # Day 9: the "fake" provider returns canned text with no network, so the whole
    # draft-attachment path (background thread, timeline event, metrics) is exercised.
    proc, url = _start({"AI_PROVIDER": "fake"})
    yield url
    _stop(proc)


@pytest.fixture(scope="session")
def base_url_noai():
    proc, url = _start({"AI_PROVIDER": "none"})
    yield url
    _stop(proc)


def wait_for(url, path, pred, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        st, body = call(url, "GET", path)
        if st == 200 and pred(body):
            return body
        time.sleep(0.2)
    raise AssertionError(f"condition not met within {timeout}s for {path}")


def call(url, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{url}{path}", data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, {"body": e.read().decode(errors="replace")}


def am_payload(status, group_key, alerts):
    """A minimal but faithful Alertmanager webhook."""
    return {
        "version": "4", "groupKey": group_key, "truncatedAlerts": 0, "status": status,
        "receiver": "incident-bot",
        "groupLabels": {"service": "activation"},
        "commonLabels": {"service": "activation"},
        "commonAnnotations": {}, "externalURL": "http://alertmanager",
        "alerts": [{
            "status": status,
            "labels": {"alertname": name, "severity": sev, "service": "activation"},
            "annotations": {"summary": f"{name} summary"},
            "startsAt": "2026-09-04T10:00:00.123456789Z",
            "endsAt": "2026-09-04T10:09:00Z" if status == "resolved" else "0001-01-01T00:00:00Z",
            "fingerprint": name.lower(),
        } for name, sev in alerts],
    }


G_CRIT = '{}/{service=~"activation|egift"}/{severity="critical"}:{service="activation"}'
G_WARN = '{}/{service=~"activation|egift"}:{service="activation"}'


def test_healthz(base_url):
    st, body = call(base_url, "GET", "/healthz")
    assert st == 200 and body["status"] == "ok"


def test_full_lifecycle(base_url):
    # 1. critical group fires -> incident opens
    st, r = call(base_url, "POST", "/alertmanager",
                 am_payload("firing", G_CRIT, [("ActivationHighErrorRate", "critical")]))
    assert st == 200 and r["status"] == "open"
    iid = r["incident"]

    # 2. a WARNING group for the same service fires -> joins the SAME incident
    st, r2 = call(base_url, "POST", "/alertmanager",
                  am_payload("firing", G_WARN, [("ActivationHighLatency", "warning")]))
    assert r2["incident"] == iid, "two groups for one service must be one incident"

    st, inc = call(base_url, "GET", f"/incidents/{iid}")
    assert inc["severity"] == "critical"            # ranked, not string-max'd
    assert set(inc["alerts"]) == {"ActivationHighErrorRate", "ActivationHighLatency"}
    assert inc["first_alert_at_iso"] == "2026-09-04T10:00:00Z"   # from startsAt, not receipt
    # (the fake provider may already have appended an ai_draft_attached event — ignore those)
    assert [e["event"] for e in inc["timeline"] if e["event"].startswith("alerts_")] == ["alerts_firing", "alerts_firing"]

    # 3. the scribe adds a note
    st, r = call(base_url, "POST", f"/incidents/{iid}/note", {"text": "Splunk: fraud_service_timeout on 100%"})
    assert st == 200 and r["events"] >= 3

    # 4. one group resolves -> still open (the other is still firing)
    call(base_url, "POST", "/alertmanager",
         am_payload("resolved", G_CRIT, [("ActivationHighErrorRate", "critical")]))
    st, inc = call(base_url, "GET", f"/incidents/{iid}")
    assert inc["status"] == "open"

    # 5. last group resolves -> resolved, duration filled in
    call(base_url, "POST", "/alertmanager",
         am_payload("resolved", G_WARN, [("ActivationHighLatency", "warning")]))
    st, inc = call(base_url, "GET", f"/incidents/{iid}")
    assert inc["status"] == "resolved"
    assert isinstance(inc["duration_min"], float)
    assert "incident_resolved" in [e["event"] for e in inc["timeline"]]   # not [-1]: a fake draft may land after it

    # 5b. Day 9: drafts were attached in the background, by the fake provider
    inc = wait_for(base_url, f"/incidents/{iid}",
                   lambda i: i.get("ai_open_draft") and i.get("ai_resolution_draft"))
    assert inc["ai_open_draft"].startswith("[fake open draft]")
    assert inc["ai_resolution_draft"].startswith("[fake resolved draft]")
    assert inc["ai_meta"]["open"]["ok"] is True
    assert "ai_draft_attached" in [e["event"] for e in inc["timeline"]]
    # Day 10: context was attached BEFORE the open draft, degraded gracefully, and the
    # hypothesis followed
    inc = wait_for(base_url, f"/incidents/{iid}", lambda i: i.get("ai_hypothesis"))
    assert inc["ai_hypothesis"].startswith("[fake hypothesis draft]")
    assert "context_attached" in [e["event"] for e in inc["timeline"]]
    assert inc["context"]["service"] == "activation"
    assert "metrics unavailable" in inc["context"]["metrics"]["error"]
    assert "deploy lookup unavailable" in inc["context"]["recent_deploys"][0]["error"]
    assert "not configured" in inc["context"]["top_error_reasons"][0]["error"]
    # Order matters only within the open pipeline (enrich -> open draft -> hypothesis). The
    # resolution draft runs on its own thread and may land earlier on a slow agent, so
    # compare against the OPEN draft's event, not the first ai_draft_attached.
    tl = inc["timeline"]
    i_ctx = next(i for i, e in enumerate(tl) if e["event"] == "context_attached")
    i_open = next(i for i, e in enumerate(tl) if e["event"] == "ai_draft_attached" and e.get("draft") == "open")
    i_hyp = next(i for i, e in enumerate(tl) if e["event"] == "ai_draft_attached" and e.get("draft") == "hypothesis")
    assert i_ctx < i_open < i_hyp
    # re-enrich on demand
    st, r = call(base_url, "POST", f"/incidents/{iid}/enrich")
    assert st == 200 and r["context"]["service"] == "activation"
    st, r = call(base_url, "GET", "/enrich/test?service=egift")
    assert st == 200 and r["collectors"]["metrics"]["ok"] is False
    # a re-draft on demand, synchronously
    st, r = call(base_url, "POST", f"/incidents/{iid}/draft?kind=resolved&wait=true")
    assert st == 200 and r["draft"].startswith("[fake resolved draft]")
    st, r = call(base_url, "POST", f"/incidents/{iid}/draft?kind=bogus")
    assert st == 400

    # 6. list + metrics
    st, lst = call(base_url, "GET", "/incidents")
    assert lst[0]["id"] == iid and lst[0]["status"] == "resolved"
    with urllib.request.urlopen(f"{base_url}/metrics", timeout=5) as r:
        txt = r.read().decode()
    assert "incidents_created_total 1.0" in txt
    assert "incidents_open 0.0" in txt
    assert 'ai_drafts_total{kind="open",outcome="ok"} 1.0' in txt

    # 7. resolved for nothing open is harmless
    st, r = call(base_url, "POST", "/alertmanager",
                 am_payload("resolved", G_CRIT, [("ActivationHighErrorRate", "critical")]))
    assert st == 200 and "unknown" in r.get("note", "")

    # 8. delete (lab only)
    st, _ = call(base_url, "DELETE", f"/incidents/{iid}")
    assert st == 200
    st, _ = call(base_url, "GET", f"/incidents/{iid}")
    assert st == 404


def test_bad_note_rejected(base_url):
    call(base_url, "POST", "/alertmanager", am_payload("firing", G_CRIT, [("X", "warning")]))
    st, lst = call(base_url, "GET", "/incidents?status=open")
    iid = lst[0]["id"]
    st, _ = call(base_url, "POST", f"/incidents/{iid}/note", {"text": "   "})
    assert st == 400
    call(base_url, "DELETE", f"/incidents/{iid}")


def test_works_without_ai(base_url_noai):
    """The most important test in the file: no provider, incident still records."""
    url = base_url_noai
    st, r = call(url, "GET", "/ai")
    assert st == 200 and r["enabled"] is False
    st, r = call(url, "POST", "/alertmanager", am_payload("firing", G_CRIT, [("X", "critical")]))
    assert st == 200 and r["status"] == "open"
    iid = r["incident"]
    st, inc = call(url, "GET", f"/incidents/{iid}")
    assert inc["status"] == "open"
    assert inc["ai_open_draft"].startswith("(AI draft unavailable")
    call(url, "POST", "/alertmanager", am_payload("resolved", G_CRIT, [("X", "critical")]))
    st, inc = call(url, "GET", f"/incidents/{iid}")
    assert inc["status"] == "resolved" and inc["duration_min"] is not None
    assert inc["ai_resolution_draft"].startswith("(AI draft unavailable")
    assert inc["ai_hypothesis"].startswith("(AI draft unavailable")
    # enrichment needs no AI: context still arrives
    inc = wait_for(url, f"/incidents/{iid}", lambda i: i.get("context"))
    assert inc["context"]["service"] == "activation"
    call(url, "DELETE", f"/incidents/{iid}")
