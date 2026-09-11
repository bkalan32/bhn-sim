# Same four namespaces as infra/local. This time nothing is imported: the cluster is empty
# and Terraform creates them — the contrast with Day 13's import morning is the point.
resource "kubernetes_namespace" "payments" {
  metadata { name = "payments" }
}
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name   = "monitoring"
    labels = { name = "monitoring" }
  }
}
resource "kubernetes_namespace" "tracing" {
  metadata {
    name   = "tracing"
    labels = { name = "tracing" }
  }
}
resource "kubernetes_namespace" "logging" {
  metadata {
    name   = "logging"
    labels = { name = "logging" }
  }
}
