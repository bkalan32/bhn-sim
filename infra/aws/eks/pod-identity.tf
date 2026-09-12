# Day 16 — how a POD gets AWS permissions (eks-notes #5). Not the node's role: since
# module v21 the instance-metadata hop limit is 1, so a pod cannot borrow the node's
# credentials at all (the PDF's "attach CloudWatchAgentServerPolicy to the node role"
# silently does nothing for Fluent Bit — B3). Two workloads need AWS: the EBS CSI driver
# (creates the incident-bot's volume) and Fluent Bit (writes to CloudWatch Logs). Each gets
# ITS OWN IAM role, trusted by the EKS Pod Identity service, associated to ITS service
# account in ITS namespace. Least privilege with a name on it — the shape IRSA had, without
# the OIDC-provider-per-cluster ceremony.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---- EBS CSI driver: the volume behind incident-bot's PVC -----------------------------
resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
# (the association for kube-system/ebs-csi-controller-sa is declared on the add-on itself, in eks.tf)

# ---- Fluent Bit: logs to CloudWatch ---------------------------------------------------
resource "aws_iam_role" "fluent_bit" {
  name               = "${local.cluster_name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}
resource "aws_iam_role_policy_attachment" "fluent_bit" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"   # logs:CreateLogGroup/Stream, PutLogEvents
}
# The service account does not exist yet (the platform root's Helm chart creates
# logging/fluent-bit on Day 16 Step 2); an association is a promise, not a lookup.
resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = module.eks.cluster_name
  namespace       = "logging"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn
}

output "pod_identity" {
  value = {
    "kube-system/ebs-csi-controller-sa" = aws_iam_role.ebs_csi.arn
    "logging/fluent-bit"                = aws_iam_role.fluent_bit.arn
    "payments/incident-bot"             = aws_iam_role.incident_bot.arn   # Day 19
  }
}

# ---- Day 19: the incident bot reads CloudWatch Logs (its logs collector on EKS) ---------
# Splunk is a container on the laptop; on EKS the bot's third collector was "not configured"
# for three days (INC-0018's follow-up). Read-only Logs Insights on the one log group Fluent
# Bit writes, and nothing else — least privilege with a name on it, like the other two.
data "aws_iam_policy_document" "incident_bot_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery", "logs:DescribeLogGroups", "logs:FilterLogEvents"]
    resources = ["arn:aws:logs:${var.region}:*:log-group:/bhn-sim/containers:*", "arn:aws:logs:${var.region}:*:log-group:/bhn-sim/containers"]
  }
  statement {
    # GetQueryResults/StopQuery are not resource-scoped in IAM; the group above is the only one queried
    effect    = "Allow"
    actions   = ["logs:GetQueryResults", "logs:StopQuery"]
    resources = ["*"]
  }
}
resource "aws_iam_role" "incident_bot" {
  name               = "${local.cluster_name}-incident-bot"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}
resource "aws_iam_role_policy" "incident_bot_logs" {
  name   = "cloudwatch-logs-insights-read"
  role   = aws_iam_role.incident_bot.id
  policy = data.aws_iam_policy_document.incident_bot_logs.json
}
resource "aws_eks_pod_identity_association" "incident_bot" {
  cluster_name    = module.eks.cluster_name
  namespace       = "payments"
  service_account = "incident-bot"        # k8s/incident-bot.yaml (Day 19)
  role_arn        = aws_iam_role.incident_bot.arn
}
