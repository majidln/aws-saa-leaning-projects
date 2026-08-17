output "bucket_id" {
  value       = aws_s3_bucket.demo.id
  description = "Bucket name"
}

output "bucket_arn" {
  value       = aws_s3_bucket.demo.arn
  description = "Bucket ARN — the resource the apply role needs permission on"
}

output "versioning_status" {
  value       = aws_s3_bucket_versioning.demo.versioning_configuration[0].status
  description = "Should read Enabled"
}
