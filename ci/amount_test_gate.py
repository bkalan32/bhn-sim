#!/usr/bin/env python3
"""Temporarily disable the amount-mix test — Day 10 Drill B, and nothing else.

    python3 ci/amount_test_gate.py disable   put a skip marker on test_activate_all_production_amounts
    python3 ci/amount_test_gate.py enable    remove it
    python3 ci/amount_test_gate.py status

Why this exists: since Day 8 the test is always on, so the velocity-check release dies in
the pipeline's Test stage before anything is built. Drill B needs the bad build to REACH
production so the enriched ticket can show a deploy seconds before the errors. The PDF
says "remove the test temporarily"; this does it reproducibly and reversibly, with a
marker that names the drill so nobody mistakes it for a real change.
"""
import pathlib
import sys

TEST = pathlib.Path(__file__).resolve().parent.parent / "services" / "activation" / "tests" / "test_app.py"
ANCHOR = '@pytest.mark.parametrize("amount", [25, 50, 100])\n'
MARK = '@pytest.mark.skip(reason="Day 10 Drill B: amount-mix test TEMPORARILY disabled on purpose — ci/amount_test_gate.py enable")\n'

src = TEST.read_text()
mode = sys.argv[1] if len(sys.argv) > 1 else "status"
if mode == "disable":
    if MARK in src:
        print("already disabled"); sys.exit(0)
    if ANCHOR not in src:
        print("anchor not found in test_app.py"); sys.exit(1)
    TEST.write_text(src.replace(ANCHOR, MARK + ANCHOR, 1))
    print("amount-mix test DISABLED (skip marker added)")
elif mode == "enable":
    if MARK not in src:
        print("already enabled"); sys.exit(0)
    TEST.write_text(src.replace(MARK, "", 1))
    print("amount-mix test ENABLED (skip marker removed)")
elif mode == "status":
    print("disabled" if MARK in src else "enabled")
else:
    print(__doc__); sys.exit(2)
