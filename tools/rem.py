#!/usr/bin/env python3
"""Talk to the remediator from your terminal — through the API server's proxy, like inc.py.

    tools/rem.py pending                 tier-2 proposals waiting for a human
    tools/rem.py approve <token> [name]  execute a proposal — THIS is the human "yes"
    tools/rem.py decline <token>         drop a proposal
    tools/rem.py actions [n]             what the remediator has done, newest first
    tools/rem.py signatures              the policy as loaded (and DRY_RUN state)
    tools/rem.py health

The approval is a capability token, not a chat message: nothing executes without someone
posting the token back. In a company this is a Slack button; the token underneath is the
same. Set INCIDENT_REMEDIATOR_URL=http://localhost:8030 to use a port-forward instead.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.request

CTX = os.getenv("KUBE_CONTEXT", "kind-bhn-sim")
PROXY = "/api/v1/namespaces/payments/services/remediator:8030/proxy"
DIRECT = os.getenv("INCIDENT_REMEDIATOR_URL", "")


def _kubectl(args):
    r = subprocess.run(["kubectl", "--context", CTX] + args, capture_output=True, text=True)
    if r.returncode != 0:
        msg = r.stderr.strip()
        if "404" in msg or "not found" in msg.lower():
            msg += "\n  (unknown, expired or already-used token? tools/rem.py pending)"
        sys.stderr.write(msg + "\n")
        sys.exit(r.returncode)
    return r.stdout


def request(method, path, body=None):
    if DIRECT:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(DIRECT + path, data=data, method=method, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=240) as r:
            return json.loads(r.read() or b"null")
    if method == "GET":
        return json.loads(_kubectl(["get", "--raw", PROXY + path]) or "null")
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body or {}, f)
        name = f.name
    try:
        return json.loads(_kubectl(["create", "--raw", PROXY + path, "-f", name]) or "null")
    finally:
        os.unlink(name)


def cmd_pending():
    p = request("GET", "/pending")
    if not p:
        print("  (nothing pending)"); return
    # Day 21: .get() throughout. A listing that crashes on one incomplete proposal hides every
    # other proposal from the human who has to approve them (found with a hand-planted drill row).
    for x in p:
        print(f"  {x.get('token', '?')}")
        print(f"    {x.get('signature', '?')} -> {x.get('action', '?')}   incident {x.get('incident')}   "
              f"proposed {x.get('created_at_iso', '?')}   expires {x.get('expires_at_iso', '?')}")
        print(f"    evidence: {json.dumps(x.get('evidence'))}")
        print(f"    rationale: {x.get('rationale', '(none recorded)')}")
        print(f"    approve:  python3 tools/rem.py approve {x['token']}")


def cmd_actions(n):
    h = request("GET", "/actions")[:n]
    if not h:
        print("  (no actions yet)"); return
    for e in h:
        print(f"  {e['at_iso']}  {e.get('mode', ''):<9} {e.get('result', ''):<9} {e.get('signature') or '-':<20} {e.get('incident') or '-':<22} {str(e.get('detail') or e.get('token') or '')[:90]}")


def main(argv):
    if not argv:
        print(__doc__); return 2
    c, a = argv[0], argv[1:]
    if c == "pending":      cmd_pending()
    elif c == "approve":    print(json.dumps(request("POST", f"/approve/{a[0]}", {"by": a[1] if len(a) > 1 else os.getenv("USER", "human")}), indent=2))
    elif c == "decline":    print(json.dumps(request("POST", f"/decline/{a[0]}")))
    elif c == "actions":    cmd_actions(int(a[0]) if a else 20)
    elif c == "signatures": print(json.dumps(request("GET", "/signatures"), indent=2))
    elif c == "health":     print(json.dumps(request("GET", "/healthz")))
    else:
        print(__doc__); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
