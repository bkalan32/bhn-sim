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
