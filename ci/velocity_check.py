#!/usr/bin/env python3
"""Apply or remove the 'velocity check' — Day 6's deliberately bad release.

    python3 ci/velocity_check.py apply     insert the check into services/activation/app.py
    python3 ci/velocity_check.py remove    take it back out

Done as an anchored insert rather than a .patch so it survives unrelated edits to app.py.
"""
import pathlib
import sys

APP = pathlib.Path(__file__).resolve().parent.parent / "services" / "activation" / "app.py"
ANCHOR = "        if random.random() < ERROR_RATE:\n"
MARK_BEGIN = "        # --- velocity check (Day 6 bad release) BEGIN ---\n"
MARK_END = "        # --- velocity check (Day 6 bad release) END ---\n"
BLOCK = MARK_BEGIN + '''        # velocity check: block suspicious high-value activations
        # Tests pass: they only ever activate $25 cards. Production sends 25/50/100.
        if req.amount >= 50:
            elapsed = time.perf_counter() - start
            fields.update(status="error", reason="velocity_check_blocked",
                          latency_ms=round(elapsed * 1000))
            log.error("activation failed", extra={"extra": fields})
            REQUESTS.labels(status="error").inc()
            LATENCY.labels(status="error").observe(elapsed)
            return PlainTextResponse("velocity check", status_code=403)

''' + MARK_END

src = APP.read_text()
mode = sys.argv[1] if len(sys.argv) > 1 else ""
if mode == "apply":
    if MARK_BEGIN in src:
        print("already applied"); sys.exit(0)
    if ANCHOR not in src:
        print("anchor not found in app.py"); sys.exit(1)
    APP.write_text(src.replace(ANCHOR, BLOCK + ANCHOR, 1))
    print("velocity check inserted into", APP.relative_to(APP.parents[2]))
elif mode == "remove":
    if MARK_BEGIN not in src:
        print("not present"); sys.exit(0)
    a = src.index(MARK_BEGIN); b = src.index(MARK_END) + len(MARK_END)
    APP.write_text(src[:a] + src[b:])
    print("velocity check removed")
else:
    print(__doc__); sys.exit(2)
