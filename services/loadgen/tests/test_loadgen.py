"""Day 21 — the traffic knob: RATE_MULTIPLIER parsing, the rate, the metrics text."""
import os
import sys
import urllib.request

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import loadgen  # noqa: E402


@pytest.mark.parametrize("raw,want", [(None, 1.0), ("", 1.0), ("1", 1.0), ("0", 0.0), ("2.5", 2.5), ("10", 10.0)])
def test_multiplier_accepts_0_to_10(raw, want):
    assert loadgen.parse_multiplier(raw) == want


@pytest.mark.parametrize("raw", ["-1", "10.1", "100", "fast", "1e3"])
def test_multiplier_refuses_everything_else(raw):
    with pytest.raises(ValueError):
        loadgen.parse_multiplier(raw)


def test_refuses_to_start_on_a_bad_knob():
    assert loadgen.main(["--multiplier", "50"]) == 2        # a typo must not become a load test


def test_effective_rps():
    assert loadgen.effective_rps(8, 1) == 8
    assert loadgen.effective_rps(8, 0) == 0
    assert loadgen.effective_rps(3, 2) == 6


def test_bodies_match_what_the_services_expect():
    a, e = loadgen.make_body("activation"), loadgen.make_body("egift")
    assert set(a) == {"card_number", "amount", "store_id"} and a["card_number"].startswith("6011")
    assert set(e) == {"customer_id", "amount", "recipient_email"}


def test_metrics_say_paused_on_purpose():
    m = loadgen.Metrics("activation", 0.0, 0.0)
    srv = loadgen.serve_metrics(m, 0)
    port = srv.server_address[1]
    txt = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=3).read().decode()
    assert 'loadgen_rate_multiplier{target="activation"} 0.0' in txt
    assert 'loadgen_target_rps{target="activation"} 0.0' in txt
    m.inc("200"); m.inc("200"); m.inc("503")
    txt = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=3).read().decode()
    assert 'loadgen_requests_total{target="activation",outcome="200"} 2' in txt
    srv.shutdown()



def test_open_loop_throughput_does_not_depend_on_latency(monkeypatch):
    """CORRECTIONS-DAY21 B3: each answer takes 0.4 s; 10 req/s configured for 2 s.
    Closed loop (Days 2-20) would send ~4. Open loop sends ~20."""
    import threading
    import time as _t
    sent, stop = [], threading.Event()

    def slow_outcome(url, body, timeout):
        sent.append(1)
        _t.sleep(0.4)
        return "200"
    monkeypatch.setattr(loadgen, "outcome", slow_outcome)
    th = threading.Thread(target=loadgen.main, args=(["--rps", "10"], stop))
    th.start()
    _t.sleep(2.0)
    stop.set()
    th.join(timeout=5)
    assert len(sent) >= 12, f"only {len(sent)} sent in 2 s at 10 req/s configured"


def test_full_pool_is_counted_not_hidden(monkeypatch):
    import threading
    import time as _t
    stop = threading.Event()
    monkeypatch.setattr(loadgen, "outcome", lambda u, b, t: (_t.sleep(1.0), "200")[1])
    seen = {}
    real_metrics = loadgen.Metrics

    def capture(*a):
        m = real_metrics(*a); seen["m"] = m; return m
    monkeypatch.setattr(loadgen, "Metrics", capture)
    th = threading.Thread(target=loadgen.main, args=(["--rps", "50", "--max-inflight", "2"], stop))
    th.start()
    _t.sleep(1.0)
    stop.set()
    th.join(timeout=5)
    assert seen["m"].counts["dropped_client_busy"] > 0
