# Day 15, Step 5 — registries. kind loaded images straight from the Docker daemon; EKS pulls
# from a registry, using the node role — no pull secrets. One repository per service.
locals {
  services = ["activation", "egift", "settlement", "incident-bot", "remediator"]
}

resource "aws_ecr_repository" "svc" {
  for_each             = toset(local.services)
  name                 = "bhn-sim/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true          # lab only: lets `destroy` remove non-empty repos
  image_scanning_configuration { scan_on_push = true }
}

# B7: without a lifecycle policy every push accumulates forever (ECR bills per GB-month, and
# Jenkins pushed ~30 builds of activation on kind). Keep the last 10 tagged, expire untagged
# layers after a day.
resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [
      { rulePriority = 1, description = "expire untagged after 1 day",
        selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 },
        action = { type = "expire" } },
      { rulePriority = 2, description = "keep the last 10 tagged",
        selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 },
        action = { type = "expire" } }
    ]
  })
}
