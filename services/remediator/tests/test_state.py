"""Day 21 — the remediator's state: single-use tokens, expiry, dedupe, and surviving a restart."""
import os
import sqlite3
import sys
import threading

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import state  # noqa: E402


def _p(token, sig="post-deploy-errors", incident="INC-1", service="activation", created=1000.0, ttl=1800):
    return {"token": token, "signature": sig, "incident": incident, "service": service,
            "created_at": created, "expires_at": created + ttl, "action": "rollback"}


@pytest.fixture()
def st(tmp_path):
    state.init(str(tmp_path))
    return tmp_path


def test_token_is_single_use(st):
    assert state.add_pending(_p("t1"))
    assert state.take("t1", now=1001)["token"] == "t1"
    assert state.take("t1", now=1002) is None                  # the double-click


def test_concurrent_takes_have_one_winner(st):
    assert state.add_pending(_p("race"))
    wins, barrier = [], threading.Barrier(8)

    def click():
        barrier.wait()
        wins.append(state.take("race", now=1001))
    ts = [threading.Thread(target=click) for _ in range(8)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sum(1 for w in wins if w) == 1


def test_expired_token_cannot_be_used_and_is_swept(st):
    assert state.add_pending(_p("old", created=0, ttl=1800))
    assert state.take("old", now=1800) is None                  # 30 min is 30 min
    assert [p["token"] for p in state.expire(now=1800)] == ["old"]
    assert state.list_pending(now=1800) == []


def test_one_pending_proposal_per_signature_and_incident(st):
    assert state.add_pending(_p("a"))
    assert not state.add_pending(_p("b"))                       # same signature, same incident
    assert state.add_pending(_p("c", incident="INC-2"))
    assert state.count_pending(now=1001) == 2


def test_withdraw_by_service(st):
    state.add_pending(_p("x", service="activation"))
    state.add_pending(_p("y", service="egift", incident="INC-9"))
    assert [p["token"] for p in state.withdraw("activation")] == ["x"]
    assert [p["token"] for p in state.list_pending(now=1001)] == ["y"]


def test_survives_a_restart(st):
    """The whole point: a deploy (a new process on the same volume) keeps both."""
    state.add_pending(_p("keep"))
    state.mark_action("settlement-crash", 4242.0)
    state._local.conn = None                                    # a new process: fresh connection
    state.init(str(st))
    assert [p["token"] for p in state.list_pending(now=1001)] == ["keep"]
    assert state.last_action("settlement-crash") == 4242.0
    assert state.last_action("never-acted") == 0.0


def test_take_leaves_no_open_transaction(st):
    state.add_pending(_p("t"))
    state.take("t", now=1001)
    other = sqlite3.connect(os.path.join(str(st), "remediator.db"), timeout=0.5)
    other.execute("BEGIN IMMEDIATE")                             # would raise 'database is locked'
    other.execute("ROLLBACK")
