# Pinned context: a Terraform provider pointed at the wrong cluster is a classic
# self-inflicted outage. `kind-bhn-sim` here means "wrong cluster" fails fast, always.
variable "kubeconfig" {
  type        = string
  default     = "~/.kube/config"
  description = "kubeconfig path (Jenkins: /root/.kube/config = ci/kubeconfig-internal.yaml)"
}
variable "kube_context" {
  type    = string
  default = "kind-bhn-sim"
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = var.kube_context
}

# helm provider 3.x: the kubernetes block is an ATTRIBUTE (kubernetes = { ... }) and
# `set` entries are lists of objects. 2.x-era examples do not parse.
provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig
    config_context = var.kube_context
  }
}
