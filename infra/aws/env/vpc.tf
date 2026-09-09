# Day 15, Step 4 — the network. kind gave you networking for free; AWS makes you choose it,
# and the choices are billable. Community-standard module rather than hand-rolled.
#
# The shape (say it in one breath): load balancers live in PUBLIC subnets; nodes and pods
# live in PRIVATE subnets and reach the internet OUTBOUND through the NAT gateway. This is
# the standard production posture and the source of a whole genre of incident ("the pods
# can't reach the payment partner's API" = a route table, a NAT, or a security group).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "bhn-sim"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  # THE COST DECISION. One NAT gateway (~$0.045/h + $0.045/GB) shared by both AZs instead
  # of one per AZ. Production runs one per AZ so an AZ outage does not take the other AZ's
  # egress with it; the lab accepts that risk to halve the meter. Either way the meter runs
  # from `apply` until `destroy` — about a dollar a day idle. Not continuing tomorrow?
  # ./scripts/152-aws-vpc.sh destroy tonight; re-apply is five minutes.
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # How EKS's load-balancer controller finds where to put things (Day 16). Missing tags
  # here are a classic "why won't my LoadBalancer Service come up" incident.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
