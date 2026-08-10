output "vpc_id" {
  value       = aws_vpc.vpc.id
  description = "ID of the created VPC"
}

output "web_subnet_ids" {
  value = [for k in keys(local.public_subnets) : aws_subnet.this[k].id]
}

output "app_subnet_ids" {
  value = [for k in keys(local.app_subnets) : aws_subnet.this[k].id]
}

output "db_subnet_ids" {
  value = [for k, v in local.subnets : aws_subnet.this[k].id if v.tier == "db"]
}