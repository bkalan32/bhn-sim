"""
enrich.py must never raise and must come back fast when a source is missing. These tests
run a fake Prometheus, an unreachable Grafana, and no Splunk at all — the degraded case
the Day 10 exit criteria ask you to prove by stopping Splunk.
"""
import http.server
import importlib
import json
import os
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


class FakeProm(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = self.path
        # anything with clamp_min -> 100 (%), latency -> 0.31, everything else -> 42
        v = "100" if "clamp_min" in q else ("0.31" if "histogram_quantile" in q else "42")
        body = json.dumps({"status": "success", "data": {"resultType": "vector",
                           "result": [{"metric": {}, "value": [time.time(), v]}]}}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def _serve(handler):
    srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_address[1]}"


def _load(env):
    for k in ("PROM_URL", "GRAFANA_URL", "GRAFANA_TOKEN", "SPLUNK_URL", "SPLUNK_PASSWORD", "ENRICH_TIMEOUT_S"):
        os.environ.pop(k, None)
    os.environ.update(env)
    import enrich
    return importlib.reload(enrich)


def test_degraded_sources_return_stubs_fast():
    prom = _serve(FakeProm)
    e = _load({"PROM_URL": prom, "GRAFANA_URL": "http://127.0.0.1:9", "ENRICH_TIMEOUT_S": "2"})  # port 9: refused
    t0 = time.time()
    ctx, meta = e.enrich("activation", since_ts=time.time())
    assert time.time() - t0 < 6, "degraded collectors must fail fast"
    # metrics came from the fake Prometheus
    assert ctx["metrics"]["error_rate_pct"] == 100.0
    assert ctx["metrics"]["p95_latency_s"] == 0.31
    assert meta["metrics"]["ok"] is True
    # grafana unreachable -> explanatory stub, not an exception
    assert "deploy lookup unavailable" in ctx["recent_deploys"][0]["error"]
    assert meta["deploys"]["ok"] is False
    # splunk not configured -> explanatory stub
    assert "SPLUNK_URL not configured" in ctx["top_error_reasons"][0]["error"]
    assert meta["logs"]["ok"] is False


def test_unknown_service_has_no_metric_map():
    e = _load({"PROM_URL": "http://127.0.0.1:9", "ENRICH_TIMEOUT_S": "1"})
    ctx, meta = e.enrich("smoke-test")
    assert "no metric map" in ctx["metrics"]["note"]
    assert meta["metrics"]["ok"] is True


class FakeGrafana(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.headers.get("Authorization") == "Bearer tok-123"
        now = time.time()
        anns = [{"time": int((now - 90) * 1000), "tags": ["deploy", "activation"], "text": "build 21: add velocity check"},
                {"time": int((now - 5 * 3600) * 1000), "tags": ["deploy", "activation"], "text": "build 20: routine"},
                {"time": int((now + 60) * 1000), "tags": ["rollback", "activation"], "text": "AUTO-ROLLBACK build 21"}]
        body = json.dumps(anns).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def test_deploys_carry_age_relative_to_alert():
    g = _serve(FakeGrafana)
    e = _load({"PROM_URL": "http://127.0.0.1:9", "GRAFANA_URL": g, "GRAFANA_TOKEN": "tok-123", "ENRICH_TIMEOUT_S": "1"})
    now = time.time()
    deploys, meta = e.recent_deploys("activation", since_ts=now)
    assert meta["ok"] is True
    kinds = [d["kind"] for d in deploys]
    assert kinds[0] == "rollback" and kinds[1] == "deploy"          # newest first
    assert deploys[1]["minutes_before_first_alert"] == 1.5           # 90 s before
    assert deploys[0]["minutes_before_first_alert"] < 0              # after the alert
    assert deploys[2]["minutes_before_first_alert"] > 290            # the 5-hour-old one
