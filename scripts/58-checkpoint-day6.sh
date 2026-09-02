#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
PASS=0; FAIL=0; t_ok(){ ok "$*"; PASS=$((PASS+1)); }; t_fail(){ warn "$*"; FAIL=$((FAIL+1)); }
step "Day 6 exit criteria"
docker exec jenkins kubectl get nodes >/dev/null 2>&1 && t_ok "jenkins can kubectl" || t_fail "jenkins cannot kubectl (50-jenkins-rebuild.sh)"
docker exec jenkins docker ps >/dev/null 2>&1 && t_ok "jenkins can docker" || t_fail "jenkins cannot docker"
( cd "$LAB_ROOT/services/activation" && [[ -d .venv ]] && . .venv/bin/activate && python -m pytest -q tests/ >/dev/null 2>&1 ) && t_ok "activation pytest green" || t_fail "pytest not green (51-test-local.sh)"
curl -fsS -o /dev/null http://localhost:8081/job/deploy-service/ 2>/dev/null && t_ok "deploy-service job exists" || t_fail "no deploy-service job"
H=$(kubectl --context "$KUBE_CONTEXT" rollout history deployment/activation -n "$PAYMENTS_NS" 2>/dev/null || true)
echo "$H" | grep -q 'build ' && t_ok "rollout history has pipeline change-causes" || t_fail "no pipeline builds in rollout history"
echo "$H" | grep -qi 'rollback' && t_ok "rollout history shows a rollback" || t_fail "no rollback in history yet"
IMG=$(kubectl --context "$KUBE_CONTEXT" get deploy activation -n "$PAYMENTS_NS" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
grep -q 'velocity check' "$LAB_ROOT/services/activation/app.py" && t_fail "app.py still contains the velocity check — 53-bad-deploy.sh revert" || t_ok "app.py is clean (running $IMG)"
[[ -s "$LAB_ROOT/incidents/INC-0006.md" ]] && t_ok "INC-0006.md" || t_fail "INC-0006.md missing"
git -C "$LAB_ROOT" status --porcelain 2>/dev/null | grep -q . && warn "uncommitted changes" || t_ok "working tree clean"
step "Score"; say "passed: $PASS   failed: $FAIL"
(( FAIL == 0 )) && ok "Day 6 complete. Day 7: health score, overview dashboard, and the first-week review." || die "Not done yet."
