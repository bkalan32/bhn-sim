output "region"          { value = var.region }
output "account_id"      { value = local.account }
output "registry"        { value = local.registry }
output "vpc_id"          { value = module.vpc.vpc_id }
output "private_subnets" { value = module.vpc.private_subnets }
output "public_subnets"  { value = module.vpc.public_subnets }
output "nat_public_ip"   { value = try(module.vpc.nat_public_ips[0], null) }
output "ecr_urls"        { value = { for k, r in aws_ecr_repository.svc : k => r.repository_url } }
