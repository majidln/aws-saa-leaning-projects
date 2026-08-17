# Deliberately boring. This stack exists so the pipeline has something real to
# plan and apply — it is not the point of the chapter. Nothing here generates a
# password or holds a secret, which is what makes it safe to post plan output
# into a pull request comment.

resource "aws_s3_bucket" "demo" {
  bucket = var.bucket

  tags = {
    Name    = var.bucket_name
    Project = "trailmark"
    Chapter = "5"
  }
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Private, unlike Chapter 1's website bucket. Nothing needs to read this from the
# internet, so all four blocks stay on.
resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 costs nothing and needs no KMS key.
resource "aws_s3_bucket_server_side_encryption_configuration" "demo" {
  bucket = aws_s3_bucket.demo.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
