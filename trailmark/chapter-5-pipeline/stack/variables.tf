variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "bucket" {
  type        = string
  description = "Bucket name. S3 bucket names are globally unique across all AWS accounts, so change this if the apply fails with BucketAlreadyExists."
  default     = "trailmark-chapter-5-pipeline-demo"
}

variable "bucket_name" {
  type        = string
  description = "Human-readable name for the Name tag"
  default     = "Trailmark Chapter 5 Pipeline Demo"
}
