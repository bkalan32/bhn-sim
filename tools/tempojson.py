#!/usr/bin/env python3
"""Parse Grafana Tempo API responses from stdin.

    curl .../api/search?q=...   | tempojson.py search
    curl .../api/traces/<id>    | tempojson.py waterfall
    curl .../api/traces/<id>    | tempojson.py services egift activation   # exit 0 if all present

Handles both the v1 shape ({"batches": [...]}) and the v2 shape
({"trace": {"resourceSpans": [...]}}).
"""
import json
import sys


def load():
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def _attr(attrs, key):
    for a in attrs or []:
        if a.get("key") == key:
            v = a.get("value", {})
            return v.get("stringValue") or v.get("intValue") or v.get("boolValue")
    return None


def spans_of(doc):
    """Flatten a trace into [(service, name, span_id, parent_id, start_ns, end_ns, attrs)]."""
    batches = doc.get("batches") or doc.get("trace", {}).get("resourceSpans") or []
    out = []
    for b in batches:
        svc = _attr(b.get("resource", {}).get("attributes"), "service.name") or "?"
        for ss in b.get("scopeSpans") or b.get("instrumentationLibrarySpans") or []:
            for s in ss.get("spans", []):
                out.append((
                    svc, s.get("name", "?"), s.get("spanId", ""), s.get("parentSpanId", ""),
                    int(s.get("startTimeUnixNano", 0)), int(s.get("endTimeUnixNano", 0)),
                    {a.get("key"): (a.get("value", {}).get("stringValue")
                                    or a.get("value", {}).get("intValue")) for a in s.get("attributes", [])},
                ))
    return out


def search():
    traces = load().get("traces", [])
    if not traces:
        print("  no traces found")
        return 1
    for t in traces:
        print(f"  {t.get('traceID','')}  {t.get('rootServiceName','?'):<11} "
              f"{t.get('rootTraceName','?'):<22} {t.get('durationMs','?')}ms")
    return 0


def waterfall():
    sp = spans_of(load())
    if not sp:
        print("  empty trace")
        return 1
    t0 = min(s[4] for s in sp)
    total = max(s[5] for s in sp) - t0
    by_id = {s[2]: s for s in sp}
    depth = {}

    def d(s):
        if s[2] in depth:
            return depth[s[2]]
        p = by_id.get(s[3])
        depth[s[2]] = 0 if p is None else d(p) + 1
        return depth[s[2]]

    for s in sorted(sp, key=lambda s: s[4]):
        dur = (s[5] - s[4]) / 1e6
        off = (s[4] - t0) / 1e6
        width = 40
        lead = int(width * off / total) if total else 0
        bar = int(max(1, width * (s[5] - s[4]) / total)) if total else 1
        label = f"{'  ' * d(s)}{s[0]} {s[1]}"
        print(f"  {label:<44} {' ' * lead}{'█' * bar}{' ' * (width - lead - bar)}  {dur:7.1f}ms")
    print(f"  {'total':<44} {' ' * width}  {total/1e6:7.1f}ms")
    # the widest span, excluding the root, is the answer to "where did the time go?"
    kids = [s for s in sp if s[3]]
    if kids:
        w = max(kids, key=lambda s: s[5] - s[4])
        print(f"\n  widest non-root span: {w[0]} {w[1]}  ({(w[5]-w[4])/1e6:.1f}ms)")
    return 0


def services(expected):
    got = {s[0] for s in spans_of(load())}
    print("  services in trace:", ", ".join(sorted(got)) or "(none)")
    missing = set(expected) - got
    if missing:
        print("  MISSING:", ", ".join(sorted(missing)))
        return 1
    return 0


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "search"
    if mode == "search":
        sys.exit(search())
    if mode == "waterfall":
        sys.exit(waterfall())
    if mode == "services":
        sys.exit(services(sys.argv[2:]))
    print("unknown mode", mode); sys.exit(2)
