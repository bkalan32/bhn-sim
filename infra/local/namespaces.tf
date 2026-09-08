# Four namespaces. `payments` was created by `kubectl apply` on Day 2 (k8s/activation.yaml,
# from which it moved today — one owner). The other three were created by Helm's
# --create-namespace on Days 1/3/4, and Helm stamps those with a `name: <namespace>` label.
# Nothing selects on it, but the first post-import plan wanted to DELETE it (CORRECTIONS
# N4): the code must describe what is, so the label is declared here and stays.
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
