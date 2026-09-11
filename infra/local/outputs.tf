output "releases" {
  description = "what Terraform believes is running — compare with `helm list -A`"
  value = {
    for r in [helm_release.kps, helm_release.pushgateway, helm_release.tempo, helm_release.otel, helm_release.fluent_bit, helm_release.newrelic] :
    r.name => { namespace = r.namespace, chart = r.chart, version = r.version, status = r.status }
  }
}
