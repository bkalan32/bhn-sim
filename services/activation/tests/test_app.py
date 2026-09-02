"""
Unit tests for the activation service.

FIX vs the PDF: these do NOT use fastapi.testclient. TestClient pulls in httpx as a
hidden dependency, and the httpx it wants varies with the starlette version (you hit
'requires the httpx2 package' on Day 2). Instead we start the real server in a
subprocess and talk to it over HTTP with the standard library — no extra deps, and it
exercises the same code path uvicorn runs in the container.
"""

import json
import os
import socket
import subprocess
import sys
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


@pytest.fixture(scope="session")
def base_url():
    port = _free_port()
    env = {**os.environ, "ERROR_RATE": "0", "BASE_LATENCY_MS": "1",
           "LATENCY_JITTER_MS": "0", "FRAUD_SVC_DOWN": "false",
           "OTEL_TRACES_EXPORTER": "none", "OTEL_METRICS_EXPORTER": "none"}
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1",
         "--port", str(port), "--log-level", "warning"],
        cwd=APP_DIR, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    url = f"http://127.0.0.1:{port}"
    # Up to 90s. A cold venv with the OpenTelemetry package set can take 20-40s to
    # import on WSL the first time (pyc compilation + antivirus scanning of ~1,500
    # files). Subsequent starts are ~2s.
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"{url}/healthz", timeout=1)
            break
        except Exception:
            if proc.poll() is not None:
                raise RuntimeError("server died:\n" + proc.stdout.read().decode())
            time.sleep(0.5)
    else:
        proc.kill()
        out = proc.stdout.read().decode(errors="replace")
        raise RuntimeError(f"server never became ready in 90s. Its output so far:\n{out[-2000:]}")
    yield url
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


def post(url, path, body):
    req = urllib.request.Request(f"{url}{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, {"body": e.read().decode(errors="replace")}


def test_healthz(base_url):
    with urllib.request.urlopen(f"{base_url}/healthz", timeout=5) as r:
        body = json.loads(r.read())
    assert r.status == 200
    assert body["status"] == "ok"           # FIX: PDF asserts the whole dict; ours also carries "version"


def test_activate_ok(base_url):
    # The PDF's test. Note the amount: 25. That detail matters on Day 6.
    status, body = post(base_url, "/activate",
                        {"card_number": "6011000012345678", "amount": 25, "store_id": "STORE-0001"})
    assert status == 200
    assert body["approved"] is True
    assert body["card_last4"] == "5678"     # never the full PAN
    assert "card_number" not in body


def test_metrics_exposed(base_url):
    with urllib.request.urlopen(f"{base_url}/metrics", timeout=5) as r:
        txt = r.read().decode()
    assert "activation_requests_total" in txt
    assert "activation_latency_seconds_bucket" in txt


# INC-0006's follow-up, implemented: the test suite should cover the amount
# distribution production actually sees. This is exactly the test that would have
# caught the velocity-check release. It is marked xfail-by-design until Day 6's
# Step 7, when you enable it — so you can watch the bad deploy sail through first.
@pytest.mark.skipif(os.getenv("TEST_PRODUCTION_AMOUNTS", "false") != "true",
                    reason="enable with TEST_PRODUCTION_AMOUNTS=true after INC-0006")
@pytest.mark.parametrize("amount", [25, 50, 100])
def test_activate_all_production_amounts(base_url, amount):
    status, body = post(base_url, "/activate",
                        {"card_number": "6011000012345678", "amount": amount, "store_id": "STORE-0001"})
    assert status == 200, f"${amount} card was rejected: {body}"
    assert body["approved"] is True
