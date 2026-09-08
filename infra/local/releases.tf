# Five Helm releases, every one pinned to the chart version that is actually running,
# every one with the SAME values it was installed with — the values files in k8s/ stay
# the single source of truth; Terraform owns that the release exists, which version,
# and which values apply.

resource "helm_release" "kps" {
  name       = "kps"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions["kps"]
  values     = [file("${path.module}/../../k8s/kps-values.yaml")]
  timeout    = 900
  wait       = true
}

# Installed on Day 5 with --set flags (serviceMonitor + honorLabels + resources). The PDF's
# resource lists two of the five, so its first apply would silently remove honorLabels and
# the resource limits (B2). The flags now live in k8s/pushgateway-values.yaml.
resource "helm_release" "pushgateway" {
  name       = "pushgateway"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-pushgateway"
  version    = var.chart_versions["pushgateway"]
  values     = [file("${path.module}/../../k8s/pushgateway-values.yaml")]
  timeout    = 300
  wait       = true
  depends_on = [helm_release.kps]   # its ServiceMonitor needs the CRD
}

resource "helm_release" "tempo" {
  name       = "tempo"
  namespace  = kubernetes_namespace.tracing.metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = var.chart_versions["tempo"]
  values     = [file("${path.module}/../../k8s/tempo-values.yaml")]
  timeout    = 300
  wait       = true
}

resource "helm_release" "otel" {
  name       = "otel"
  namespace  = kubernetes_namespace.tracing.metadata[0].name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = var.chart_versions["otel"]
  values     = [file("${path.module}/../../k8s/otel-values.yaml")]
  timeout    = 300
  wait       = true
  depends_on = [helm_release.tempo]
}

# The rendered values file is gitignored (HEC token + a moving IP), so Terraform renders
# the same template 22-fluent-bit.sh renders, from variables tf.sh supplies (B3). After a
# Docker restart moves Splunk, `tf.sh plan` shows exactly one change: the Host line.
resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  namespace  = kubernetes_namespace.logging.metadata[0].name
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = var.chart_versions["fluent-bit"]
  values = [
    replace(replace(replace(
      file("${path.module}/../../k8s/fluent-bit-values.yaml.tmpl"),
      "__SPLUNK_IP__", var.splunk_ip),
      "__SPLUNK_TOKEN__", var.splunk_hec_token),
      "__TLS__", var.splunk_hec_tls)
  ]
  timeout = 300
  wait    = true
}
