module "network" {
  source = "./modules/network"
  prefix = var.prefix
}

module "app-tier" {
  source            = "./modules/app-tier"
  prefix            = var.prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  app_subnet_ids    = module.network.app_subnet_ids
  app_port          = 3000
  db_secret_arn     = module.db-tier.secret_arn
}

module "db-tier" {
  source        = "./modules/db-tier"
  prefix        = var.prefix
  vpc_id        = module.network.vpc_id
  app_sg        = module.app-tier.app_sg
  db_subnet_ids = module.network.db_subnet_ids
  db_port       = 5432
}

output "alb_dns" {
  value       = module.app-tier.alb-dns
  description = "Public ALB DNS — curl http://<this>/health"
}

output "vpc_id" {
  value       = module.network.vpc_id
  description = "VPC ID"
}

output "app_sg_id" {
  value       = module.app-tier.app_sg
  description = "App security group ID (source for RDS ingress)"
}

output "db_endpoint" {
  value       = module.db-tier.db_endpoint
  description = "RDS hostname (private; should fail from your laptop)"
}

output "db_port" {
  value       = module.db-tier.db_port
  description = "RDS port"
}

output "db_name" {
  value       = module.db-tier.db_name
  description = "Initial database name"
}

output "db_secret_arn" {
  value       = module.db-tier.secret_arn
  description = "Secrets Manager ARN for DB credentials"
}
