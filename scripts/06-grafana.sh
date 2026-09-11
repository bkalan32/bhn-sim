#!/usr/bin/env bash
# Day 1, Step 7 — get the Grafana password and open the dashboard.
#
# Goal today is to see what a HEALTHY cluster looks like, so you can recognise an
# unhealthy one later. Do not configure anything.

source "$(dirname "$0")/lib.sh"
require_cluster

step "Grafana admin credentials"
PASS=$(grafana_admin_password); [[ -n "$PASS" ]] || die "no Grafana admin password in secret/grafana-admin or secret/kps-grafana"
say "  user: admin"
say "  pass: ${PASS}"
dim "(the guide's version emits no trailing newline, so the password runs into your prompt;"
dim " this script adds one. Single-quoted jsonpath is also the safer bash habit.)"
printf 'grafana admin / %s\n' "$PASS" > "$CHECKPOINTS/day1-grafana-credentials.txt"
chmod 600 "$CHECKPOINTS/day1-grafana-credentials.txt"

GRAFANA_PORT="${GRAFANA_PORT:-3000}"   # Day 16: GRAFANA_PORT=3001 for the EKS Grafana while kind's keeps 3000
step "Port-forwarding Grafana ($KUBE_CONTEXT) to localhost:$GRAFANA_PORT"
say "Open http://localhost:$GRAFANA_PORT in your WINDOWS browser — WSL2 forwards localhost"
say "into the distro automatically, so no extra flag is needed."
dim "If it ever stops working after a Windows sleep/resume, run 'wsl --shutdown' in"
dim "PowerShell and start over; the fallback is --address=0.0.0.0."
echo
say "Browse the built-in dashboards, especially:"
say "  Kubernetes / Compute Resources / Cluster"
say "  Kubernetes / Compute Resources / Namespace (Pods)"
say "  Node Exporter / Nodes"
echo
dim "Ctrl-C to stop the port-forward."
k port-forward svc/"${HELM_RELEASE}-grafana" -n "$MONITORING_NS" "$GRAFANA_PORT":80
