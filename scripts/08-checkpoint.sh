#!/usr/bin/env bash
# Day 1 exit criteria — the guide's "Day 1 is done when" list, as an actual test.

source "$(dirname "$0")/lib.sh"

PASS=0; FAIL=0
t_ok()   { ok   "$*"; PASS=$((PASS+1)); }
t_fail() { warn "$*"; FAIL=$((FAIL+1)); }

step "Day 1 exit criteria"

# 1. seven tools
MISS=""
for t in docker kubectl kind helm terraform python3 git; do have "$t" || MISS="$MISS $t"; done
[[ -z "$MISS" ]] && t_ok "All seven tools answer --version" || t_fail "Missing:$MISS"

# 2. node Ready
if kubectl --context "$KUBE_CONTEXT" get nodes 2>/dev/null | grep -q ' Ready '; then
  t_ok "kubectl get nodes shows Ready (context $KUBE_CONTEXT)"
else
  t_fail "No Ready node on context $KUBE_CONTEXT"
fi

# 3. monitoring healthy
if kubectl --context "$KUBE_CONTEXT" get pods -n "$MONITORING_NS" >/dev/null 2>&1; then
  BAD=$(kubectl --context "$KUBE_CONTEXT" get pods -n "$MONITORING_NS" \
        --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
  (( BAD == 0 )) && t_ok "Monitoring pods all Running or Completed" \
                 || t_fail "$BAD monitoring pod(s) not Running/Completed"
else
  t_fail "Namespace $MONITORING_NS not found"
fi

# 4. grafana reachable (only if a port-forward is up)
if curl -fsS --max-time 5 -o /dev/null http://localhost:3000 2>/dev/null; then
  t_ok "Grafana answers on localhost:3000"
else
  warn "Grafana not answering on :3000 — expected unless scripts/06-grafana.sh is running in another terminal"
fi

# 5. jenkins reachable
if curl -fsS --max-time 5 -o /dev/null http://localhost:8081 2>/dev/null; then
  t_ok "Jenkins answers on localhost:8081"
else
  t_fail "Jenkins not answering on :8081 — run scripts/07-jenkins.sh"
fi

# 6. repo pushed
if git -C "$LAB_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$LAB_ROOT" remote -v | grep -q .; then
    t_ok "Git repo with a remote configured"
  else
    t_fail "Git repo exists but has no remote — create the private GitHub repo 'bhn-sim' and push"
  fi
else
  t_fail "Not a git repo yet — run: git init && git add -A && git commit -m 'Day 1'"
fi

step "Score"
say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 1 complete. Day 2 builds the card activation API." \
                || die "Day 1 not done yet — see the failures above."
