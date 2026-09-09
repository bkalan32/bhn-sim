# Day 15, Step 3 — the state bucket. This tiny root keeps LOCAL state on purpose: the bucket
# that will hold everyone else's state cannot hold its own (the chicken-and-egg every team
# has). Its local state describes one bucket and holds no secret; it is gitignored anyway.
#
#   terraform -chdir=infra/aws/backend init && terraform -chdir=infra/aws/backend apply
#   (scripts/151-aws-state.sh does this and writes the bucket name into env/backend.hcl)
terraform {
  required_version = ">= 1.10"          # S3-native locking (use_lockfile) arrived in 1.10
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"                 # CORRECTIONS-DAY15 B1: Ohio, not Singapore
}
variable "initials" {
  type    = string
  default = "bk"
}

provider "aws" {
  region = var.region
  default_tags { tags = { project = "bhn-sim", day = "15", managed_by = "terraform" } }
}

# Bucket names are global; four random hex chars make the name unique without a guess.
resource "random_id" "suffix" { byte_length = 2 }

resource "aws_s3_bucket" "tfstate" {
  bucket        = "bhn-sim-tfstate-${var.initials}-${random_id.suffix.hex}"
  force_destroy = false                 # never destroy a state bucket by accident
}

# Every state write becomes a recoverable version — the undo button for a bad apply.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

# Non-negotiable hygiene for any bucket, ever.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "bucket" { value = aws_s3_bucket.tfstate.bucket }
output "region" { value = var.region }
