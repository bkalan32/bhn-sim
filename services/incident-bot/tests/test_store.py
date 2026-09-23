"""Day 21 — the SQLite store: round trip, append-only timeline, filters, JSON import."""
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import store  # noqa: E402


def _inc(iid, status="open", service="activation", opened=1000.0, events=1):
    return {"id": iid, "status": status, "service": service, "join_key": service, "severity": "critical",
            "opened_at": opened, "alerts": ["ActivationHighErrorRate"], "groups": {"g": "firing"},
            "timeline": [{"ts": opened + i, "event": "alerts_firing", "n": i} for i in range(events)]}


@pytest.fixture()
def db(tmp_path):
    store.init(str(tmp_path))
    return tmp_path


def test_round_trip_keeps_doc_and_timeline_order(db):
    store.save(_inc("INC-1-a", events=3))
    got = store.load("INC-1-a")
    assert got["alerts"] == ["ActivationHighErrorRate"] and got["groups"] == {"g": "firing"}
    assert [e["n"] for e in got["timeline"]] == [0, 1, 2]
    assert store.load("INC-nope") is None


def test_timeline_is_append_only(db):
    inc = _inc("INC-2-a", events=2)
    store.save(inc)
    inc["timeline"].append({"ts": 5000, "event": "note", "text": "scribe"})
    store.save(inc)
    assert len(store.load("INC-2-a")["timeline"]) == 3
    inc["timeline"] = inc["timeline"][:1]                     # history "rewritten"
    with pytest.raises(store.AppendOnlyViolation):
        store.save(inc)
    assert len(store.load("INC-2-a")["timeline"]) == 3        # and nothing was lost


def test_status_since_and_newest_first(db):
    store.save(_inc("INC-old", opened=1000))
    store.save(_inc("INC-new", opened=3000))
    store.save(_inc("INC-done", status="resolved", opened=2000))
    assert [i["id"] for i in store.summaries()] == ["INC-new", "INC-done", "INC-old"]
    assert [i["id"] for i in store.summaries(status="open")] == ["INC-new", "INC-old"]
    assert [i["id"] for i in store.summaries(since=2000)] == ["INC-new", "INC-done"]
    assert "timeline" not in store.summaries()[0]           # summaries are cheap
    assert store.count("open") == 2


def test_find_open_by_join_key(db):
    store.save(_inc("INC-r", status="resolved", service="egift", opened=100))
    assert store.find_open("egift") is None
    store.save(_inc("INC-o", service="egift", opened=200))
    assert store.find_open("egift")["id"] == "INC-o"


def test_imports_day8_json_once(tmp_path):
    rec = _inc("INC-1790182530-dbcf", events=6)
    (tmp_path / "INC-1790182530-dbcf.json").write_text(json.dumps(rec))
    (tmp_path / "reports").mkdir()                              # not an incident: left alone
    info = store.init(str(tmp_path))
    assert info["imported"] == 1
    assert len(store.load("INC-1790182530-dbcf")["timeline"]) == 6
    assert (tmp_path / "INC-1790182530-dbcf.json.imported").exists()
    assert store.init(str(tmp_path))["imported"] == 0           # idempotent


def test_delete(db):
    store.save(_inc("INC-d", events=2))
    assert store.delete("INC-d") and store.load("INC-d") is None and not store.delete("INC-d")
