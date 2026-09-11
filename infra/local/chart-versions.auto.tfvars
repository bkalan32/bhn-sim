# Written by scripts/130-tf-import.sh from `helm list -A` on the day of import. COMMITTED:
# these pins are the reason `terraform apply` never upgrades a chart by accident.
chart_versions = {
  "kps" = "88.6.2"   # kube-prometheus-stack-88.6.2 in monitoring, rev 3
  "pushgateway" = "3.8.0"   # prometheus-pushgateway-3.8.0 in monitoring, rev 1
  "tempo" = "1.24.4"   # tempo-1.24.4 in tracing, rev 1
  "otel" = "0.172.0"   # opentelemetry-collector-0.172.0 in tracing, rev 1
  "fluent-bit" = "0.58.1"   # fluent-bit-0.58.1 in logging, rev 7
  "newrelic" = "8.0.24"   # nri-bundle, Day 17 (pinned by hand: not installed by helm first, so 130 never saw it)
}
