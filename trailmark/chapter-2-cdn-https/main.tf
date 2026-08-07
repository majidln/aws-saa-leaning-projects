### Create an S3 bucket to host the frontend files
resource "aws_s3_bucket" "chapter2_launch_page" {
  bucket = var.bucket

  tags = {
    Name = var.bucket_name
  }
}

resource "aws_s3_bucket_versioning" "chapter2_launch_page_versioning" {
  bucket = aws_s3_bucket.chapter2_launch_page.id
  versioning_configuration {
    status = "Enabled"
  }
}

### Define the content types for the frontend files
locals {
  content_types = {
    css  = "text/css"
    html = "text/html"
    js   = "application/javascript"
    json = "application/json"
    txt  = "text/plain"
  }
}

### Upload the frontend files to the S3 bucket
resource "aws_s3_object" "frontend" {
  bucket       = aws_s3_bucket.chapter2_launch_page.id
  key          = each.value
  source       = "./frontend/${each.value}"
  etag         = filemd5("./frontend/${each.value}")
  content_type = lookup(local.content_types, element(split(".", each.value), length(split(".", each.value)) - 1), "text/plain")

  for_each = fileset("./frontend/", "*")
}

resource "aws_s3_bucket_public_access_block" "chapter2_launch_page_public_access_block" {
  bucket = aws_s3_bucket.chapter2_launch_page.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#### Create a bucket policy to allow CloudFront to access the S3 bucket
resource "aws_s3_bucket_policy" "chapter2_launch_page_public_policy" {
  bucket = aws_s3_bucket.chapter2_launch_page.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalReadWrite"
        Effect = "Allow"

        Principal = {
          Service = "cloudfront.amazonaws.com"
        }

        Action = [
          "s3:GetObject",
        ]

        Resource = [
          "${aws_s3_bucket.chapter2_launch_page.arn}/*"
        ]

        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
          }
        }
      }
    ]
  })
}
#### Create an origin access identity for CloudFront to access the S3 bucket
resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "default-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

### Create cloudfront distribution to serve the frontend files
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name = aws_s3_bucket.chapter2_launch_page.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.chapter2_launch_page.id
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for S3 bucket"
  default_root_object = "index.html"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.chapter2_launch_page.id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/error.html"
  }

  custom_error_response {
    error_code = 403
    response_code = 403
    response_page_path = "/error.html"
  }
}

output "frontend_endpoint" {
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
  description = "The endpoint of the S3 bucket hosting the frontend."
}