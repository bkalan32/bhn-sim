#!/usr/bin/env bash
# Provision every dashboard in dashboards/*.json as a ConfigMap — as code, not clicks.
#
# Why: the chart's Grafana has no persistent volume. Dashboards imported through the UI
# live in a SQLite file inside the pod, and the pod is replaced by every helm upgrade,
# node restart, or OOM. You lost all four on Day 8 when 81-alertmanager-route.sh rolled
# Grafana. The Day 4 Tempo datasource survived because it is a ConfigMap; this does the
# same for dashboards. The sidecar loads them within ~30s and re-loads on every change,
# so from now on "re-import" = re-run this script (or just: kubectl apply).
#
#   ./scripts/09-grafana-dashboards.sh          apply all
#   ./scripts/09-grafana-dashboards.sh --check  list what Grafana has loaded
#
# Provisioned dashboards are READ-ONLY in the UI (Grafana marks them). That is the
# point: edit the JSON in git, re-run, done. To experiment in the UI, "Save as" a copy.
source "$(dirname "$0")/lib.sh"
require_cluster

# Import-format dashboards carry an __inputs block and reference the datasource as
# ${DS_PROMETHEUS}, which the Import dialog resolves by asking you. The sidecar has no
# dialog, so resolve it here: kube-prometheus-stack provisions Prometheus with uid
# "prometheus" (and our Tempo datasource is uid "tempo").
PROM_UID=$(k get cm -n "$MONITORING_NS" -l grafana_datasource=1 -o json 2>/dev/null \
  | python3 -c 'import json,sys,re
for cm in json.load(sys.stdin)["items"]:
    for v in cm["data"].values():
        m = re.search(r"uid:\s*(\S+)", v)
        if "type: prometheus" in v and m: print(m.group(1)); raise SystemExit
print("prometheus")' 2>/dev/null || echo prometheus)

if [[ "${1:-}" == "--check" ]]; then
  step "Dashboards Grafana has loaded from ConfigMaps"
  k get cm -n "$MONITORING_NS" -l grafana_dashboard=1 -o custom-columns=NAME:.metadata.name,AGE:.metadata.creationTimestamp | sed 's/^/  /'
  exit 0
fi

step "Rendering dashboards/*.json -> ConfigMaps (datasource uid: $PROM_UID)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
for f in "$LAB_ROOT"/dashboards/*.json; do
  name=$(basename "$f" .json)
  python3 - "$f" "$TMP/$name.json" "$PROM_UID" <<'EOF'
import json, sys
src, dst, uid = sys.argv[1:4]
d = json.load(open(src))
d.pop("__inputs", None); d.pop("__requires", None)
d["id"] = None
s = json.dumps(d).replace("${DS_PROMETHEUS}", uid)
open(dst, "w").write(s)
EOF
  k create configmap "dash-$name" -n "$MONITORING_NS" --from-file="$name.json=$TMP/$name.json" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k label configmap "dash-$name" -n "$MONITORING_NS" grafana_dashboard=1 --overwrite >/dev/null
  ok "dash-$name"
done

step "Waiting for the sidecar to load them (~30s)"
sleep 30
PW=$(k get secret kps-grafana -n "$MONITORING_NS" -o jsonpath='{.data.admin-password}' | base64 -d)
k exec -n "$MONITORING_NS" deploy/kps-grafana -c grafana -- \
  curl -s -u "admin:$PW" 'http://localhost:3000/api/search?type=dash-db' 2>/dev/null \
  | python3 -c 'import json,sys
d=json.load(sys.stdin)
ours=[x for x in d if any(w in x.get("title","").lower() for w in ("activation","egift","overview"))]
for x in ours: print("  %-32s /d/%s" % (x["title"], x["uid"]))
print("  (%d dashboards total, incl. the chart built-ins)" % len(d))' || warn "could not list via the Grafana API — check the UI"
echo
say "Hand-imported copies of the same dashboards (if any survived) will now appear twice;"
say "delete the non-provisioned one. From now on: edit JSON in git, re-run this script."
ok "Grafana: http://localhost:3000/dashboards  (./scripts/06-grafana.sh if the port-forward died)"
