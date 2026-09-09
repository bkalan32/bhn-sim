# Day 15 — the real environment root. State lives in the versioned S3 bucket from
# infra/aws/backend, locked by S3 itself (Terraform >= 1.10: use_lockfile, no DynamoDB).
# The bucket name and region come from backend.hcl, written by scripts/151-aws-state.sh:
#   terraform -chdir=infra/aws/env init -backend-config=backend.hcl
terraform {
  required_version = ">= 1.10"
  backend "s3" {
    key          = "env/terraform.tfstate"
    use_lockfile = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
