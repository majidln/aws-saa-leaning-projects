### Create an S3 bucket to host the frontend files
resource "aws_s3_bucket" "state_backend" {
  bucket = var.bucket
}

resource "aws_s3_bucket_versioning" "state_backend_versioning" {
  bucket = aws_s3_bucket.state_backend.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "state_backend_public_access_block" {
  bucket = aws_s3_bucket.state_backend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value       = aws_s3_bucket.state_backend.bucket
  description = "Output for bucket name"
}