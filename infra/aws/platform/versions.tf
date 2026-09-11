# Day 16, Step 2 — the Day 13 platform layer, pointed at EKS. This root is infra/local
# with three differences, each commented where it lives: the provider wiring (aws-lab
# context), Fluent Bit's backend (CloudWatch instead of Splunk), and a values overlay for
# a control plane you do not run. State: its own key in the Day 15 bucket.
terraform {
  required_version = ">= 1.10"
  backend "s3" {
    key          = "platform/terraform.tfstate"
    use_lockfile = true
  }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
  }
}
