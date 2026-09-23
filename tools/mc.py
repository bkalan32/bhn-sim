#!/usr/bin/env python3
"""
tools/mc.py — Mission Control from the terminal. Day 21.

Not a back door: every command here is an HTTP call to the same /api routes the UI will use,
with the same bearer token, and it arrives with `X-Entrance: api` and `X-Operator: $USER` — so it
meets the same catalog, the same tiers, the same audit row as a button. Tier 2 still needs a
second, separate `approve`.

  python3 tools/mc.py overview                    the ten-second screen, as JSON
  python3 tools/mc.py actions                     the catalog
  python3 tools/mc.py run <action> [k=v ...] [--reason "..."]
                                                  e.g. run rerun_settlement
                                                       run set_fault target=activation knob=FRAUD_SVC_DOWN value=true --reason drill
  python3 tools/mc.py approvals                   what is waiting for a human (mission control + remediator)
  python3 tools/mc.py approve <token> | decline <token>
  python3 tools/mc.py audit [N]                   the last N audit rows (default 15)
  python3 tools/mc.py events                      follow the live feed (Ctrl-C to stop)
  python3 tools/mc.py get /api/...                any GET

Needs: kubectl -n payments port-forward svc/mission-control 8040:8040   (or MC_URL=...)
Token: ~/.bhn-sim/mc-token (scripts/210-mc-config.sh), never printed.
"""
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.getenv("MC_URL", "http://localhost:8040").rstrip("/")
TOKEN_FILE = os.path.expanduser("~/.bhn-sim/mc-token")


def token():
    try:
        return open(TOKEN_FILE).read().strip()
    except FileNotFoundError:
        sys.exit(f"no token at {TOKEN_FILE} — ./scripts/210-mc-config.sh")


def call(method, path, body=None, stream=False):
    req = urllib.request.Request(URL + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json",
                                          "X-Operator": os.getenv("USER", "operator"), "X-Entrance": "api"})
    try:
        r = urllib.request.urlopen(req, timeout=None if stream else 130)
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {URL} ({e.reason}) — is the port-forward running? "
                 "kubectl -n payments port-forward svc/mission-control 8040:8040")
    return r if stream else json.loads(r.read() or b"null")


def show(x):
    print(json.dumps(x, indent=2, default=str))


def main(a):
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return
    c, rest = a[0], a[1:]
    if c == "overview":
        show(call("GET", "/api/overview"))
    elif c == "actions":
        for x in call("GET", "/api/actions")["actions"]:
            print(f"  tier {x['tier']}  {x['id']:<26} {x['title']}   params: {', '.join(x['params']) or '-'}")
    elif c == "run":
        if not rest:
            sys.exit("run <action> [k=v ...] [--reason text]")
        reason = ""
        if "--reason" in rest:
            i = rest.index("--reason"); reason = " ".join(rest[i + 1:]); rest = rest[:i]
        params = dict(kv.split("=", 1) for kv in rest[1:])
        show(call("POST", f"/api/actions/{rest[0]}", {"params": params, "reason": reason}))
    elif c == "approvals":
        ps = call("GET", "/api/approvals")
        if not ps:
            print("  (nothing waiting)")
        for p in ps:
            print(f"  {p['token']}\n    {p.get('action') or p.get('signature')} {json.dumps(p.get('params'))}  "
                  f"asked by {p.get('operator')} via {p.get('entrance')}  expires {p.get('expires_at_iso')}\n"
                  f"    approve: python3 tools/mc.py approve {p['token']}")
    elif c in ("approve", "decline"):
        show(call("POST", f"/api/approvals/{rest[0]}/{c}", {}))
    elif c == "audit":
        n = int(rest[0]) if rest else 15
        for r in reversed(call("GET", f"/api/audit?limit={n}")):
            print(f"  {r['ts_iso']}  {r['operator']:<10} {r['entrance']:<8} t{r['tier']}  {r['action']:<24} "
                  f"{r['result']:<9} {json.dumps(r['params'])[:60]}{'  token ' + r['approval_token'] if r.get('approval_token') else ''}")
    elif c == "events":
        r = call("GET", "/api/events", stream=True)
        try:
            for line in r:
                line = line.decode().rstrip()
                if line.startswith(("event:", "data:")):
                    print(line, flush=True)
                elif line == "":
                    print(flush=True)
        except KeyboardInterrupt:
            pass
    elif c == "get":
        show(call("GET", rest[0]))
    else:
        sys.exit(f"unknown command {c} — python3 tools/mc.py --help")


if __name__ == "__main__":
    main(sys.argv[1:])
