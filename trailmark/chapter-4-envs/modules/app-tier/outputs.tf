output "alb-dns" {
  value       = aws_lb.alb.dns_name
  description = "DNS name of the ALB"
}

output "app_sg" {
  value       = aws_security_group.app_sg.id
  description = "ID of the app security group"
}