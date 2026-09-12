"""Day 19: the SPL -> Logs Insights translator (no AWS needed). The copilot and the collectors
speak SPL; on EKS the bot answers from CloudWatch. The subset is small and the refusals are
explicit — a tool result that says WHY is what the copilot needs to rephrase."""
import pytest

import enrich


def test_stats_by_reason():
    q = enrich.spl_to_insights("index=main app.service=activation app.status=error | stats count by app.reason | sort -count")
    assert 'filter app.service = "activation" and app.status = "error"' in q
    assert "stats count(*) as count by app.reason" in q and q.endswith("sort count desc")


def test_quoted_values_and_head():
    q = enrich.spl_to_insights('app.service="egift" app.reason!="ok" | stats count by app.reason | head 3')
    assert 'app.service = "egift" and app.reason != "ok"' in q and q.endswith("limit 3")


def test_plain_search_sorts_newest_first():
    q = enrich.spl_to_insights("search app.service=settlement")
    assert q.startswith("fields @timestamp") and q.endswith("sort @timestamp desc")


def test_table():
    q = enrich.spl_to_insights("app.service=activation | table app.msg, app.reason")
    assert q.startswith("fields app.msg, app.reason")


@pytest.mark.parametrize("bad", ["app.service=activation | eval x=1", "app.service=activation | dedup app.reason", "activation failed"])
def test_refusals_say_why(bad):
    with pytest.raises(ValueError) as e:
        enrich.spl_to_insights(bad)
    assert "not supported" in str(e.value) or "only key=value" in str(e.value)


def test_backend_flag(monkeypatch):
    monkeypatch.setattr(enrich, "LOGS_BACKEND", "cloudwatch"); monkeypatch.setattr(enrich, "CW_LOG_GROUP", "/bhn-sim/containers")
    assert enrich.configured()["logs_backend"] == "cloudwatch"
    monkeypatch.setattr(enrich, "LOGS_BACKEND", "none"); monkeypatch.setattr(enrich, "CW_LOG_GROUP", "")
    rows, meta = enrich.top_log_reasons("activation")
    assert meta["ok"] is False and "not configured" in rows[0]["error"]
