#!/usr/bin/env python3
"""Talk to the incident bot from your terminal — no port-forward needed.

    tools/inc.py list [open|resolved]        one line per incident
    tools/inc.py show <id>                   the full record
    tools/inc.py timeline <id>               the timeline, human-readable
    tools/inc.py note <id> "what you did"    append a bridge note (Day 9)
    tools/inc.py delete <id>                 lab only
    tools/inc.py webhook <firing|resolved>   post a SYNTHETIC Alertmanager webhook (smoke test)
    tools/inc.py drafts <id>                 print the AI drafts on a record (Day 9)
    tools/inc.py draft <id> <open|resolved>  (re)generate a draft now and print it (Day 9)
    tools/inc.py ai                          which provider/model the bot is using

How it reaches the bot: the Kubernetes API server can proxy HTTP to any Service
(`kubectl get --raw /api/v1/namespaces/payments/services/incident-bot:8020/proxy/...`).
That works from anywhere kubectl works, survives pod restarts, and needs no port.
Set INCIDENT_BOT_URL=http://localhost:8020 to talk to a port-forward instead.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

CTX = os.getenv("KUBE_CONTEXT", "kind-bhn-sim")
PROXY = "/api/v1/namespaces/payments/services/incident-bot:8020/proxy"
DIRECT = os.getenv("INCIDENT_BOT_URL", "")


def _kubectl(args, body=None):
    cmd = ["kubectl", "--context", CTX] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr.strip() + "\n")
        sys.exit(r.returncode)
    return r.stdout


def request(method, path, body=None):
    if DIRECT:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(DIRECT + path, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"null")
    if method == "GET":
        return json.loads(_kubectl(["get", "--raw", PROXY + path]) or "null")
    if method == "DELETE":
        return json.loads(_kubectl(["delete", "--raw", PROXY + path]) or "null")
    # POST: kubectl create --raw sends the file body verbatim.
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body or {}, f)
        name = f.name
    try:
        return json.loads(_kubectl(["create", "--raw", PROXY + path, "-f", name]) or "null")
    finally:
        os.unlink(name)


def cmd_list(status=None):
    incs = request("GET", "/incidents" + (f"?status={status}" if status else ""))
    if not incs:
        print("  (no incidents)"); return
    print(f"  {'ID':<22} {'STATUS':<9} {'SEV':<9} {'SERVICE':<12} {'OPENED (UTC)':<21} {'MIN':>6}  ALERTS")
    for i in incs:
        print(f"  {i['id']:<22} {i['status']:<9} {i.get('severity') or '-':<9} {i.get('service') or '-':<12} "
              f"{(i.get('opened_at_iso') or '')[:20]:<21} {str(i.get('duration_min') or ''):>6}  {', '.join(i.get('alerts') or [])}")


def cmd_show(iid):
    print(json.dumps(request("GET", f"/incidents/{iid}"), indent=2))


def cmd_timeline(iid):
    inc = request("GET", f"/incidents/{iid}")
    print(f"  {inc['id']}  {inc['status']}  service={inc.get('service')}  severity={inc.get('severity')}")
    print(f"  first alert {inc.get('first_alert_at_iso')}   opened {inc.get('opened_at_iso')}   "
          f"resolved {inc.get('resolved_at_iso') or '-'}   duration {inc.get('duration_min', '-')} min")
    for e in inc.get("timeline", []):
        if e["event"] in ("alerts_firing", "alerts_resolved"):
            names = ", ".join(f"{a['name']}({a['severity']})" for a in e.get("alerts", []))
            print(f"  {e['ts_iso']}  {e['event']:<17} {names}")
        elif e["event"] == "note":
            print(f"  {e['ts_iso']}  note              {e.get('text')}")
        else:
            print(f"  {e['ts_iso']}  {e['event']:<17} {json.dumps({k: v for k, v in e.items() if k not in ('ts', 'ts_iso', 'event')})}")


def cmd_drafts(iid):
    inc = request("GET", f"/incidents/{iid}")
    for kind, field in (("open", "ai_open_draft"), ("resolved", "ai_resolution_draft")):
        meta = (inc.get("ai_meta") or {}).get(kind, {})
        head = f"{kind.upper()} DRAFT"
        if meta:
            head += f"  [{meta.get('provider')}/{meta.get('model')}  {meta.get('latency_ms')} ms  " \
                    f"{meta.get('input_tokens')}->{meta.get('output_tokens')} tokens]"
        print("=" * 78); print(head); print("=" * 78)
        print(inc.get(field) or "(none yet)"); print()


def cmd_draft(iid, kind):
    r = request("POST", f"/incidents/{iid}/draft?kind={kind}&wait=true")
    if r.get("draft"):
        print(r["draft"])
    else:
        print(json.dumps(r, indent=2))


def cmd_webhook(status):
    """A synthetic webhook in Alertmanager's exact shape, service=smoke-test."""
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    payload = {
        "version": "4", "groupKey": '{}/{service="smoke-test"}:{service="smoke-test"}',
        "status": status, "receiver": "incident-bot",
        "groupLabels": {"service": "smoke-test"}, "commonLabels": {"service": "smoke-test"},
        "commonAnnotations": {}, "externalURL": "http://tools/inc.py", "truncatedAlerts": 0,
        "alerts": [{"status": status,
                    "labels": {"alertname": "SmokeTest", "severity": "warning", "service": "smoke-test"},
                    "annotations": {"summary": "synthetic alert from tools/inc.py"},
                    "startsAt": now, "endsAt": now if status == "resolved" else "0001-01-01T00:00:00Z",
                    "fingerprint": "smoketest"}],
    }
    print(json.dumps(request("POST", "/alertmanager", payload)))


def main(argv):
    if not argv:
        print(__doc__); return 2
    c, a = argv[0], argv[1:]
    if c == "list":       cmd_list(a[0] if a else None)
    elif c == "show":     cmd_show(a[0])
    elif c == "timeline": cmd_timeline(a[0])
    elif c == "note":     print(json.dumps(request("POST", f"/incidents/{a[0]}/note", {"text": " ".join(a[1:])})))
    elif c == "delete":   print(json.dumps(request("DELETE", f"/incidents/{a[0]}")))
    elif c == "webhook":  cmd_webhook(a[0] if a else "firing")
    elif c == "drafts":   cmd_drafts(a[0])
    elif c == "draft":    cmd_draft(a[0], a[1] if len(a) > 1 else "open")
    elif c == "ai":       print(json.dumps(request("GET", "/ai"), indent=2))
    else:
        print(__doc__); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
