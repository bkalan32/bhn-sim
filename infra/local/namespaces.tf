# The four namespaces. payments used to be declared in k8s/activation.yaml as well; it
# is not any more (CORRECTIONS-DAY13 B4) — one object, one owner.
resource "kubernetes_namespace" "payments" {
  metadata { name = "payments" }
}
resource "kubernetes_namespace" "monitoring" {
  metadata { name = "monitoring" }
}
resource "kubernetes_namespace" "tracing" {
  metadata { name = "tracing" }
}
resource "kubernetes_namespace" "logging" {
  metadata { name = "logging" }
}
