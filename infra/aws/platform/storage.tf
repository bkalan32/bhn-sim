# Day 16 (CORRECTIONS-DAY16 B12): EKS 1.30+ ships NO default StorageClass. kind's
# local-path was the default, so a PVC with no storageClassName (the incident-bot's, Day 8)
# just worked; on EKS the same claim sits Pending — "no persistent volumes available for
# this claim and no storage class is set" — and the pod behind it never schedules. The
# fix is a default class, as code: gp3 (the current EBS type — cheaper and faster than the
# legacy gp2 class EKS still creates), provisioned by the EBS CSI add-on (whose AWS
# permissions come from Pod Identity — infra/aws/eks/pod-identity.tf), encrypted, bound
# only once a pod is scheduled so the volume lands in that pod's availability zone.
# Kubernetes >= 1.28 assigns a new default class to existing unclassed PVCs retroactively.
resource "kubernetes_storage_class_v1" "gp3_default" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}
