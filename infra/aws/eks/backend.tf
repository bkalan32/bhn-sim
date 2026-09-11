# Day 16 — the compute root. Its OWN state key: the cluster ($0.10/h + nodes) comes and
# goes daily; the network and registry ($1/day) stay up across a whole week of warm
# starts. The PDF welds both into one root, so it could never have one without the other
# (CORRECTIONS-DAY16 D1). Bucket + region from backend.hcl (scripts/160 copies env's).
terraform {
  required_version = ">= 1.10"
  backend "s3" {
    key          = "eks/terraform.tfstate"
    use_lockfile = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
