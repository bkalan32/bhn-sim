#!/usr/bin/env bash
# Day 13, Step 4 — one real change, the IaC way: edit, plan, READ the plan, apply, verify,
# commit. The change: Alertmanager repeat_interval 4h -> 6h. On Day 8 this was a helm
# command you remembered or not; today it is a diff with an author and a timestamp.
source "$(dirname "$0")/lib.sh"
require_cluster
cd "$LAB_ROOT" || exit 1
TF="$LAB_ROOT/infra/local/tf.sh"
F=k8s/kps-values.yaml

step "Edit"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean — commit the import first"
grep -q 'repeat_interval: 4h' "$F" || die "expected 'repeat_interval: 4h' in $F (already changed?)"
sed -i 's/repeat_interval: 4h/repeat_interval: 6h/' "$F"
git --no-pager diff --stat; git --no-pager diff "$F" | grep -E '^[-+]\s' | sed 's/^/  /'

step "Plan — exactly one release should change, and only for this"
"$TF" plan -input=false -no-color > infra/local/plan.txt 2>&1 || { tail -20 infra/local/plan.txt; die "plan failed"; }
grep -E '^\s*[~+-] |Plan:|repeat_interval' infra/local/plan.txt | head -20 | sed 's/^/  /'
grep -q 'Plan: 0 to add, 1 to change, 0 to destroy' infra/local/plan.txt \
  || { warn "the plan is not '0 add, 1 change, 0 destroy' — read infra/local/plan.txt before applying"; }
echo; read -rp "  Read it. Apply? [Enter = yes, Ctrl-C = no] " _

step "Apply (helm upgrade under the hood, pinned version, same values file + this diff)"
set +e; "$TF" apply -input=false -auto-approve -no-color > infra/local/apply.txt 2>&1; RC=$?; set -e
grep -E '^(helm_release|Apply complete)|^\s*(│ )?Error:' infra/local/apply.txt | sed 's/^/  /'
(( RC == 0 )) || die "terraform apply failed (exit $RC) — full output: infra/local/apply.txt"

step "Verify in Alertmanager's live config (the config-reloader polls; up to ~2 min)"
OK=0
for _ in $(seq 1 24); do
  alertmanager_get /api/v2/status | grep -q 'repeat_interval: 6h' && { OK=1; break; }; sleep 5
done
(( OK )) && ok "Alertmanager reports repeat_interval: 6h" || die "Alertmanager still shows the old interval — kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c config-reloader"

step "Commit — the change now has a diff, an author and a timestamp"
git add "$F"
git commit -q -m "Alertmanager: repeat_interval 4h -> 6h (Day 13, via Terraform)" && ok "committed $(git log -1 --format=%h)"
"$TF" plan -input=false -detailed-exitcode >/dev/null 2>&1 && ok "plan clean again" || warn "plan not clean after apply — ./infra/local/tf.sh plan"
ok "Next: ./scripts/132-drift-drill.sh inject"
