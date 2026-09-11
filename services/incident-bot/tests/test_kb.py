"""Day 17 — the knowledge base parser and scorer. Runs in the pipeline's test stage, so a
malformed kb/*.md or a scorer regression fails the build before it ships."""
import os
import textwrap

import pytest

import kb

GOOD = textwrap.dedent("""\
    ---
    id: kb-001
    title: Fraud dependency outage or timeout
    services: [activation, egift]
    symptoms:
      - ActivationHighErrorRate firing, error rate climbing toward 100%
      - reason=fraud_service_timeout dominates app.reason
    discriminating_checks:
      - "Splunk: app.service=activation app.status=error | stats count by app.reason"
    fix: Restore the fraud dependency. No safe automated action.
    tier: 3
    learned_from: [INC-0001, INC-0008]
    ---
    Notes: fail-fast reduced blast radius.
    """)

BAD_RELEASE = GOOD.replace("kb-001", "kb-002").replace("Fraud dependency outage or timeout", "Bad release") \
    .replace("ActivationHighErrorRate firing, error rate climbing toward 100%", "ActivationErrorBudgetBurnFast within minutes of a deploy") \
    .replace("reason=fraud_service_timeout dominates app.reason", "velocity_check_blocked dominates app.reason; a deploy in the last 30 minutes")


def test_parse_good():
    e = kb.parse(GOOD, "fraud.md")
    assert e["id"] == "kb-001" and e["tier"] == 3
    assert e["services"] == ["activation", "egift"]
    assert len(e["symptoms"]) == 2 and e["symptoms"][1].startswith("reason=fraud")
    assert e["learned_from"] == ["INC-0001", "INC-0008"]
    assert e["notes"].startswith("Notes:")


@pytest.mark.parametrize("mutate,msg", [
    (lambda s: s.replace("---\nid", "id", 1), "no front matter"),
    (lambda s: s.replace("tier: 3\n", ""), "missing tier"),
    (lambda s: s.replace("kb-001", "kb1"), "id must look like"),
    (lambda s: s.replace("tier: 3", "tier: high"), "tier must be"),
    (lambda s: s.replace("symptoms:\n", "symptoms: {bad}\n"), "must be a list"),
])
def test_parse_rejects_bad_shapes(mutate, msg):
    with pytest.raises(kb.KBError) as ei:
        kb.parse(mutate(GOOD), "x.md")
    assert msg in str(ei.value)


def _kbdir(tmp_path):
    (tmp_path / "fraud.md").write_text(GOOD)
    (tmp_path / "bad-release.md").write_text(BAD_RELEASE)
    (tmp_path / "README.md").write_text("# not an entry")
    return str(tmp_path)


def test_load_skips_readme(tmp_path):
    entries = kb.load(_kbdir(tmp_path))
    assert [e["id"] for e in entries] == ["kb-002", "kb-001"]      # sorted by filename


def test_search_ranks_the_right_pattern_first(tmp_path):
    d = _kbdir(tmp_path)
    fraud = kb.search("activation ActivationHighErrorRate fraud_service_timeout issuer_declined", d)
    assert fraud and fraud[0]["id"] == "kb-001" and fraud[0]["score"] > fraud[-1]["score"] or len(fraud) == 1
    bad = kb.search("activation ActivationErrorBudgetBurnFast velocity_check_blocked deploy build 19", d)
    assert bad and bad[0]["id"] == "kb-002"


def test_search_returns_nothing_for_unrelated_symptoms(tmp_path):
    assert kb.search("incident-bot IncidentBotDown", _kbdir(tmp_path)) == []


def test_query_from_incident_uses_alerts_reasons_and_deploys():
    inc = {"service": "activation",
           "alerts": [{"alertname": "ActivationHighErrorRate", "summary": "Cards are being declined at the till"}],
           "context": {"top_error_reasons": [{"reason": "fraud_service_timeout", "count": 435}],
                       "recent_deploys": [{"text": "build 19: add velocity check", "minutes_before_first_alert": 2.6}],
                       "metrics": {"p95_latency_s": 0.48}}}
    q = kb.query_from_incident(inc)
    for w in ("ActivationHighErrorRate", "fraud_service_timeout", "build 19", "0.48"):
        assert w in q


def test_render_names_ids_and_checks(tmp_path):
    hits = kb.search("activation ActivationHighErrorRate fraud_service_timeout", _kbdir(tmp_path))
    out = kb.render(hits)
    assert "[kb-001]" in out and "discriminating checks" in out and "tier 3" in out
    assert "no entry matches" in kb.render([])


def test_missing_dir_is_empty_not_fatal(tmp_path):
    assert kb.load(str(tmp_path / "nope")) == []
