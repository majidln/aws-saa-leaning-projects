module "network" {
  source             = "./../modules/network"
  prefix             = var.prefix
  environment        = terraform.workspace
  single_nat_gateway = var.single_nat_gateway
}

module "app-tier" {
  source               = "./../modules/app-tier"
  prefix               = var.prefix
  vpc_id               = module.network.vpc_id
  public_subnet_ids    = module.network.public_subnet_ids
  app_subnet_ids       = module.network.app_subnet_ids
  app_port             = var.app_port
  db_secret_arn        = module.db-tier.secret_arn
  instance_type        = var.instance_type
  asg_min_size         = var.asg_min_size
  asg_max_size         = var.asg_max_size
  asg_desired_capacity = var.asg_desired_capacity
  environment          = terraform.workspace
}

module "db-tier" {
  source                  = "./../modules/db-tier"
  prefix                  = var.prefix
  vpc_id                  = module.network.vpc_id
  app_sg                  = module.app-tier.app_sg
  db_subnet_ids           = module.network.db_subnet_ids
  db_port                 = var.db_port
  environment             = terraform.workspace
  recovery_window_in_days = var.recovery_window_in_days
  db_instance_class       = var.db_instance_class
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
