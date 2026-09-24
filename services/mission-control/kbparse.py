"""
kbparse.py — the KB front matter, parsed exactly as the incident bot parses it (services/incident-bot/kb.py).

It is NOT YAML: the format is `key: value`, `key: [a, b]` and `- item` lines, and three entries have
colons inside list items that a YAML parser rejects (CORRECTIONS-DAY24 N1). Two parsers of one
format would disagree about some file one day; this is a copy of the bot's `parse`, and
tests/test_gameday.py::test_kb_parser_mirrors_the_bot runs both over every kb/*.md and fails on
any difference.
"""

import re

REQUIRED = ("id", "title", "services", "symptoms", "discriminating_checks", "fix", "tier", "learned_from")


class KBError(ValueError):
    pass


def _parse_scalar(v: str):
    v = v.strip()
    if v.startswith("[") and v.endswith("]"):
        return [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


def parse(text: str, path: str = "<text>") -> dict:
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.S)
    if not m:
        raise KBError(f"{path}: no front matter (---\\n...\\n---)")
    fm, body = m.group(1), m.group(2)
    entry, key = {}, None
    for ln in fm.splitlines():
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if re.match(r"^\s+-\s", ln):
            if key is None:
                raise KBError(f"{path}: list item before any key: {ln!r}")
            item = ln.split("-", 1)[1].strip().strip("'\"")
            if not isinstance(entry.get(key), list):
                if entry.get(key) not in (None, "", []):
                    raise KBError(f"{path}: {key} must be a list — it has a value AND '- item' lines")
                entry[key] = []
            entry[key].append(item)
            continue
        km = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", ln)
        if not km:
            raise KBError(f"{path}: cannot parse line {ln!r} (only 'key: value', '[a, b]' and '- item' are allowed)")
        key, val = km.group(1), km.group(2)
        entry[key] = _parse_scalar(val) if val.strip() else []
    missing = [k for k in REQUIRED if k not in entry or entry[k] in ("", [])]
    if missing:
        raise KBError(f"{path}: missing {', '.join(missing)}")
    if not re.match(r"^kb-\d{3}$", str(entry["id"])):
        raise KBError(f"{path}: id must look like kb-001, got {entry['id']!r}")
    for k in ("services", "symptoms", "discriminating_checks", "learned_from"):
        if not isinstance(entry[k], list):
            raise KBError(f"{path}: {k} must be a list")
    try:
        entry["tier"] = int(entry["tier"])
    except (TypeError, ValueError):
        raise KBError(f"{path}: tier must be 1, 2 or 3")
    entry["notes"] = body.strip()
    entry["path"] = path
    entry["text"] = text
    return entry
