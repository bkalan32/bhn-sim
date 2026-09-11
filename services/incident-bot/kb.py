"""
kb — the troubleshooting knowledge base, retrievable by code. Day 17, Part B.

Seven-ish markdown files (kb/*.md), each with front matter in a strict shape (kb/README.md).
This module reads them, scores them against a bag of observed symptoms, and returns the
best matches with their full text — for the incident bot's hypothesis prompt and for the
copilot's `search_kb` tool. Same code, both callers, so they cannot disagree about what
the KB says.

Retrieval is DELIBERATELY dumb: term overlap between the query and each entry's
symptoms/services/title, with alert names and app.reason values weighted because those
are the words a ticket actually contains. Seven documents do not need embeddings; the
lesson is the wiring (PDF, Step 6). Swap `score()` for a vector later — keep the interface.

No third-party imports: the bot's image carries fastapi/uvicorn/prometheus-client only,
so the front matter (a YAML subset: scalars, `[a, b]` lists, `- item` lists) is parsed by
hand. Anything outside that subset is a validation error, on purpose — the shape is the
contract (172-kb.sh validates every file before it ships the ConfigMap).
"""

import glob
import os
import re

KB_DIR = os.getenv("KB_DIR", "/kb")           # the bot: a ConfigMap mount; the copilot passes the repo's kb/
REQUIRED = ("id", "title", "services", "symptoms", "discriminating_checks", "fix", "tier", "learned_from")
_TOKEN = re.compile(r"[a-z0-9_:.]+")
_NEG = re.compile(r"\b(?:not|never|rather than|instead of|unlike)\s+[A-Za-z0-9_:.=]+", re.I)
# Words that appear in every entry and every ticket; they carry no signal.
_STOP = {"the", "a", "an", "and", "or", "of", "in", "on", "to", "is", "for", "with", "not", "no", "at",
         "by", "from", "this", "that", "it", "its", "be", "as", "are", "was", "vs", "than", "then", "if",
         "app", "status", "error", "errors", "rate", "firing", "alert", "service", "services", "may",
         "min", "minutes", "seconds", "last", "new", "one", "two", "kubectl", "prometheus", "splunk"}


class KBError(ValueError):
    pass


# ------------------------------------------------------------------ parse ---
def _parse_scalar(v: str):
    v = v.strip()
    if v.startswith("[") and v.endswith("]"):
        return [x.strip().strip("'\"") for x in v[1:-1].split(",") if x.strip()]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    return v


def parse(text: str, path: str = "<text>") -> dict:
    """Front matter between the first two '---' lines -> dict; the rest -> 'notes'."""
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.S)
    if not m:
        raise KBError(f"{path}: no front matter (---\\n...\\n---)")
    fm, body = m.group(1), m.group(2)
    entry, key = {}, None
    for ln in fm.splitlines():
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if re.match(r"^\s+-\s", ln):                       # "  - item" under the current key
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


def load(kb_dir: str = None) -> list:
    """Every kb/*.md except README.md, parsed. Raises KBError on the first bad file."""
    d = kb_dir or KB_DIR
    out = []
    for p in sorted(glob.glob(os.path.join(d, "*.md"))):
        if os.path.basename(p).lower() == "readme.md":
            continue
        with open(p, encoding="utf-8") as f:
            out.append(parse(f.read(), os.path.basename(p)))
    return out


# ------------------------------------------------------------------ score ---
def tokens(s: str) -> set:
    return {t for t in _TOKEN.findall(str(s).lower()) if t not in _STOP and len(t) > 2}


def score(entry: dict, query_terms: set) -> float:
    """Overlap between the query and the entry, weighted toward the words that discriminate:
    an alert name or an app.reason value matching is worth more than a generic noun."""
    if not query_terms:
        return 0.0
    # "not fraud_service_timeout" in a symptom is a discriminator AGAINST, not a match:
    # drop the word that follows a negation before tokenising.
    sym = tokens(" ".join(_NEG.sub(" ", ln) for ln in entry["symptoms"]))
    svc = {s.lower() for s in entry["services"]}
    ttl = tokens(entry["title"])
    hits = 0.0
    for t in query_terms:
        if t in sym:
            # alert names (CamelCase flattened) and reason values (snake_case) are the signal
            hits += 3.0 if ("_" in t or t.endswith("rate") or t.endswith("fast") or t.endswith("slow")
                            or t.endswith("failed") or t.endswith("stale") or t.endswith("records")
                            or t.endswith("down") or t.endswith("looping") or t.endswith("backoff")) else 1.0
        if t in ttl:
            hits += 1.0
        if t in svc:
            hits += 0.5
    return hits


def search(query: str, kb_dir: str = None, top: int = 2, min_score: float = 2.0) -> list:
    """Top entries for a bag of symptoms. Returns [] when nothing scores above min_score —
    'no pattern matches' is a valid, useful answer, and the callers say so."""
    entries = load(kb_dir)
    q = tokens(query)
    scored = sorted(((score(e, q), e) for e in entries), key=lambda x: -x[0])
    return [dict(e, score=round(s, 1)) for s, e in scored[:top] if s >= min_score]


def query_from_incident(inc: dict) -> str:
    """The bag of words a ticket offers: alert names, service, summaries, top log reasons."""
    parts = [str(inc.get("service", ""))]
    for a in inc.get("alerts", []) or []:
        if isinstance(a, dict):
            parts += [str(a.get("alertname", "")), str(a.get("summary", "")), str(a.get("service", ""))]
        else:
            parts.append(str(a))
    ctx = inc.get("context") or {}
    for r in ctx.get("top_error_reasons", []) or []:
        if isinstance(r, dict) and r.get("reason"):
            parts.append(str(r["reason"]))
    for d in ctx.get("recent_deploys", []) or []:
        if isinstance(d, dict) and d.get("text"):
            parts.append("deploy " + str(d["text"]))
    m = ctx.get("metrics") or {}
    if isinstance(m, dict) and m.get("p95_latency_s") not in (None, ""):
        parts.append("p95 latency %.2fs" % float(m["p95_latency_s"]))
    return " ".join(parts)


def render(entries: list) -> str:
    """The block a prompt gets: id, title, symptoms, checks, fix, tier, incidents."""
    if not entries:
        return "KNOWLEDGE BASE: no entry matches the observed symptoms (say so; do not force a match)."
    out = ["KNOWLEDGE BASE MATCHES (team memory from past incidents — cite the entry id when it applies, "
           "run its discriminating checks before concluding, and say if the evidence contradicts it):"]
    for e in entries:
        out.append(f"\n[{e['id']}] {e['title']}  (score {e.get('score', '?')}; seen in {', '.join(e['learned_from'])}; tier {e['tier']})")
        out.append("  symptoms: " + " | ".join(e["symptoms"]))
        out.append("  discriminating checks: " + " | ".join(e["discriminating_checks"]))
        out.append("  fix: " + e["fix"])
        if e.get("notes"):
            out.append("  notes: " + e["notes"][:600])
    return "\n".join(out)
