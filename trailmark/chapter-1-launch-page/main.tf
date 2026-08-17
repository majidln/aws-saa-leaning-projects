resource "aws_s3_bucket" "chapter1_launch_page" {
  bucket = var.bucket

  tags = {
    Name = var.bucket_name
  }
}

locals {
  content_types = {
    css  = "text/css"
    html = "text/html"
    js   = "application/javascript"
    json = "application/json"
    txt  = "text/plain"
  }
}

resource "aws_s3_object" "frontend" {
  bucket       = aws_s3_bucket.chapter1_launch_page.id
  key          = each.value
  source       = "./frontend/${each.value}"
  etag         = filemd5("./frontend/${each.value}")
  content_type = lookup(local.content_types, element(split(".", each.value), length(split(".", each.value)) - 1), "text/plain")

  for_each = fileset("./frontend/", "*")
}

resource "aws_s3_bucket_public_access_block" "chapter1_launch_page_public_access_block" {
  bucket = aws_s3_bucket.chapter1_launch_page.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "chapter1_launch_page_public_policy" {
  bucket = aws_s3_bucket.chapter1_launch_page.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = ["${aws_s3_bucket.chapter1_launch_page.arn}/*"]
      }
    ]
  })
}

resource "aws_s3_bucket_website_configuration" "chapter1_launch_page_website" {
  bucket = aws_s3_bucket.chapter1_launch_page.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

output "frontend_endpoint" {
  value       = aws_s3_bucket_website_configuration.chapter1_launch_page_website.website_endpoint
  description = "The endpoint of the S3 bucket hosting the frontend."
}