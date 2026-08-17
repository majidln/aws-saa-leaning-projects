output "db_endpoint" {
  value       = aws_db_instance.db_instance.address
  description = "RDS instance hostname"
}

output "db_port" {
  value       = aws_db_instance.db_instance.port
  description = "RDS instance port"
}

output "db_name" {
  value       = aws_db_instance.db_instance.db_name
  description = "Initial database name"
}

output "secret_arn" {
  value       = aws_secretsmanager_secret.generated_password.arn
  description = "ARN of the Secrets Manager secret with DB credentials"
}
