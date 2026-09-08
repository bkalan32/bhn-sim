# Day 13 — the platform layer as code. Terraform owns namespaces and Helm releases;
# the pipeline owns the application workloads. Two owners for one object is how fights
# start, so that line is drawn in README.md and nothing crosses it.
terraform {
  required_version = ">= 1.9"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
  }
  # Local state, path supplied at init (infra/local/tf.sh): your WSL tree by default,
  # /repo/infra/local/terraform.tfstate from the Jenkins drift job — one state, two
  # readers. State holds the Fluent Bit values including the HEC token, so it is
  # gitignored. In a company this is a remote backend with locking (S3 + DynamoDB);
  # the shape is identical, only the path changes.
  backend "local" {}
}
