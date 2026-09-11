variable "region" {
  type        = string
  default     = "us-east-2"             # one variable, everywhere (CORRECTIONS-DAY15 B1)
  description = "AWS region for the whole lab"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "bhn-sim", managed_by = "terraform" }
  }
}

# The network comes from the env root — found by the tags Day 15 put on it, not by a
# copied ID. This is exactly how the AWS load-balancer controller finds subnets, so the
# same tags do double duty. If these lookups fail, the env root is not applied.
data "aws_vpc" "lab" {
  filter {
    name   = "tag:Name"
    values = ["bhn-sim"]
  }
  filter {
    name   = "tag:project"
    values = ["bhn-sim"]
  }
}
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.lab.id]
  }
  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}
