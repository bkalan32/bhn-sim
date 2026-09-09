variable "region" {
  type        = string
  default     = "us-east-2"             # one variable, everywhere (CORRECTIONS-DAY15 B1)
  description = "AWS region for the whole lab"
}

provider "aws" {
  region = var.region
  # Every resource the lab creates carries these; Cost Explorer can then answer
  # "what did Day 16 cost?" (docs/aws-costs.md rule 6), and an orphan is findable.
  default_tags {
    tags = { project = "bhn-sim", managed_by = "terraform" }
  }
}

# AZ names differ per region; derive the first two instead of hardcoding (B5).
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
data "aws_caller_identity" "current" {}

locals {
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  account  = data.aws_caller_identity.current.account_id
  registry = "${local.account}.dkr.ecr.${var.region}.amazonaws.com"
}
