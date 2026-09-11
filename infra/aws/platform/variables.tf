# The SAME chart versions kind runs. scripts/162-eks-platform.sh copies
# infra/local/chart-versions.auto.tfvars here before every plan, so the two roots cannot
# disagree: "what version is on EKS?" has the answer "what version is on kind?" — for the
# platform as well as the services (Day 15 D2).
variable "chart_versions" {
  type        = map(string)
  description = "release name -> chart version (chart-versions.auto.tfvars, copied from infra/local)"
}

# Charts come from a LOCAL cache, not from GitHub on every plan (Day 15 D4): tf.sh runs
# `helm pull` once per chart+version into charts/ (gitignored), and the releases below
# point at the .tgz files. A plan on a bad evening no longer needs eight downloads to
# succeed — and a plan with no internet at all still renders.
locals {
  charts = "${path.module}/charts"
  chart_file = {
    kps         = "${local.charts}/kube-prometheus-stack-${var.chart_versions["kps"]}.tgz"
    pushgateway = "${local.charts}/prometheus-pushgateway-${var.chart_versions["pushgateway"]}.tgz"
    tempo       = "${local.charts}/tempo-${var.chart_versions["tempo"]}.tgz"
    otel        = "${local.charts}/opentelemetry-collector-${var.chart_versions["otel"]}.tgz"
    fluent_bit  = "${local.charts}/fluent-bit-${var.chart_versions["fluent-bit"]}.tgz"
  }
}
