# The five Helm releases of infra/local/releases.tf, same values files from k8s/ (the
# single source of truth for both clusters), same pinned versions. Charts come from the
# local cache (variables.tf) instead of a repository URL, so `repository` is absent and
# `chart` is a path — the only textual difference on four of the five.

resource "helm_release" "kps" {
  name      = "kps"
  namespace = kubernetes_namespace.monitoring.metadata[0].name
  chart     = local.chart_file["kps"]
  # Difference 3 of 3: an overlay for a control plane AWS runs. Later files win.
  values = [
    file("${path.module}/../../../k8s/kps-values.yaml"),
    file("${path.module}/../../../k8s/kps-values-eks.yaml"),
  ]
  timeout = 900
  wait    = true
  # kps-values.yaml points Grafana at secret/grafana-admin (Day 13 B10). On kind, 134
  # minted it from the chart's own; here scripts/162 creates it before this apply, with
  # kubectl — outside Terraform, so the password is in no state file.
}

resource "helm_release" "pushgateway" {
  name       = "pushgateway"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  chart      = local.chart_file["pushgateway"]
  values     = [file("${path.module}/../../../k8s/pushgateway-values.yaml")]
  timeout    = 300
  wait       = true
  depends_on = [helm_release.kps]   # its ServiceMonitor needs the CRD
}

resource "helm_release" "tempo" {
  name      = "tempo"
  namespace = kubernetes_namespace.tracing.metadata[0].name
  chart     = local.chart_file["tempo"]
  values    = [file("${path.module}/../../../k8s/tempo-values.yaml")]
  timeout   = 300
  wait      = true
}

resource "helm_release" "otel" {
  name       = "otel"
  namespace  = kubernetes_namespace.tracing.metadata[0].name
  chart      = local.chart_file["otel"]
  values     = [file("${path.module}/../../../k8s/otel-values.yaml")]
  timeout    = 300
  wait       = true
  depends_on = [helm_release.tempo]
}

# Difference 2 of 3: the backend. Splunk is a container on the laptop; from a VPC in Ohio
# it is unreachable and shipping to it is a detour. Same collector, CloudWatch output, no
# token anywhere — credentials arrive through Pod Identity (infra/aws/eks/pod-identity.tf).
resource "helm_release" "fluent_bit" {
  name      = "fluent-bit"
  namespace = kubernetes_namespace.logging.metadata[0].name
  chart     = local.chart_file["fluent_bit"]
  values = [
    replace(file("${path.module}/../../../k8s/fluent-bit-cloudwatch.yaml.tmpl"), "__REGION__", var.region)
  ]
  timeout = 300
  wait    = true
}
