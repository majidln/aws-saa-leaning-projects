output "alb-dns" {
  value       = aws_lb.alb.dns_name
  description = "DNS name of the ALB"
}