# Day 16, Step 1 — the managed cluster. Community module, pinned; the decisions are the
# comments. Nodes in PRIVATE subnets (no public IPs, egress through Day 15's NAT); the API
# endpoint PUBLIC so kubectl works from the laptop — the standard starter posture.
#
# Verified against terraform-aws-modules/eks v21 source (CORRECTIONS-DAY16 B2–B4): v21
# hard-codes bootstrap_self_managed_addons = false, so a cluster with NO `addons` block —
# the PDF's file — has no CNI, no CoreDNS, no kube-proxy, and its nodes never go Ready.
# The add-ons are declared here. The IMDS hop limit defaults to 1 since v21, so "attach a
# policy to the node role" no longer gives pods AWS permissions; the two workloads that
# need any (the EBS CSI driver, Fluent Bit → CloudWatch) get them the current way, EKS Pod
# Identity — see pod-identity.tf.

locals {
  cluster_name = "bhn-sim"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = "1.33"

  vpc_id     = data.aws_vpc.lab.id
  subnet_ids = data.aws_subnets.private.ids

  # Public endpoint, open to the internet, authenticated by IAM (SSO). Production narrows
  # endpoint_public_access_cidrs to the office/VPN or goes private + bastion.
  endpoint_public_access = true

  # Maps the identity that runs `apply` (your SSO role) to cluster-admin through an EKS
  # ACCESS ENTRY — the current mechanism; the aws-auth ConfigMap in older docs is legacy.
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API"

  # Control-plane logs to CloudWatch: the only view you get of a control plane that is not
  # yours (eks-notes #4). One day of retention — this cluster lives for hours.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  # The add-ons EKS no longer installs by itself (v21). vpc-cni and the pod-identity agent
  # go in BEFORE compute: a node that joins without a CNI sits NotReady.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      # Two t3.mediums hold 17 pods each by default (one IP per pod, ENI-limited); the
      # platform + five services is ~30 pods. Prefix delegation hands each ENI /28 blocks
      # instead of single IPs, and managed node groups then compute max-pods themselves.
      # Pod density on EKS is an IP-address problem — eks-notes #6.
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" }
      })
    }
    eks-pod-identity-agent = { before_compute = true }
    # The incident-bot's PersistentVolumeClaim (Day 8, B3) needs a storage driver; kind had
    # local-path built in, EKS needs the EBS CSI add-on — with AWS permissions, via Pod Identity.
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # Day 16 (CORRECTIONS-DAY16 B13): every lab tool reaches Prometheus, Alertmanager, the bot
  # and the remediator through the API server's service proxy (`kubectl get --raw
  # .../services/<svc>:<port>/proxy`, Day 8). On kind that is one machine talking to itself.
  # Here the control plane sits in AWS's VPC and reaches pods through the cluster security
  # group -> node security group, and the module admits it only on the ports Kubernetes
  # itself needs (10250, 443, the webhook ports). 8020/8030/9090/9093 time out. Open the
  # control plane -> nodes on every port: the proxy is a network path, not a k8s feature.
  node_security_group_additional_rules = {
    ingress_cluster_to_node_all = {
      description                   = "control plane to pods on any port (API service proxy)"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    lab = {
      # THE COST DECISION: SPOT buys t3.medium at a steep discount for the risk of a
      # two-minute interruption notice. For a one-day lab that is free money, and if an
      # interruption happens mid-drill you get to watch a Deployment reschedule (Day 2's
      # two replicas earning their keep). Two instance types = more spot pools to draw from.
      instance_types = ["t3.medium", "t3a.medium"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      # Two nodes, not one: the monitoring stack plus five services need the room, and a
      # single-node cluster hides every scheduling behaviour worth learning.
    }
  }

  tags = { day = "16" }
}

output "cluster_name" { value = local.cluster_name }   # v21 output is module.eks.cluster_name, not .name (B4)
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "node_group" { value = keys(module.eks.eks_managed_node_groups) }
output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.region} --profile lab --alias aws-lab"
}
