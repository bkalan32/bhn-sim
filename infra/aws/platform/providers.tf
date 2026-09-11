# Difference 1 of 3 from infra/local: the context. `aws-lab` is what
# scripts/161-eks-kubeconfig.sh writes (aws eks update-kubeconfig --alias aws-lab), an
# exec-auth entry that mints a token from the SSO profile on every call — nothing
# long-lived on disk. Pinned here so this root can never plan against kind, and kind's
# root can never plan against EKS. Two clusters in one kubeconfig is the day's most likely
# self-inflicted incident; the pin is the seatbelt.
variable "kubeconfig" {
  type    = string
  default = "~/.kube/config"
}
variable "kube_context" {
  type    = string
  default = "aws-lab"
}
variable "region" {
  type        = string
  default     = "us-east-2"             # one variable, everywhere (CORRECTIONS-DAY15 B1)
  description = "rendered into Fluent Bit's CloudWatch output"
}

provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = var.kube_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig
    config_context = var.kube_context
  }
  # Same as Day 13 (B8): without this the provider cannot see drift. The rendered
  # manifests land in state — which is in S3, versioned, private, encrypted — and hold no
  # secret (Grafana's password is a Secret this root never reads; Fluent Bit has no token).
  experiments = {
    manifest = true
  }
}
