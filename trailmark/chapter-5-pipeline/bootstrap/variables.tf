variable "prefix" {
  type        = string
  description = "Prefix for resource names"
  default     = "chapter-5-pipeline"
}

variable "region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "stack_bucket" {
  type        = string
  description = "Bucket the pipeline manages. Must match var.bucket in ../stack — they are separate root configs, so nothing enforces this for you."
  default     = "trailmark-chapter-5-pipeline-demo"
}

variable "github_environment" {
  type        = string
  description = "GitHub Environment the apply job runs in. Must match `environment:` in chapter-5-apply.yml exactly, and the environment must exist in repo settings with required reviewers."
  default = "chapter-5-deploy"
}

variable "state_bucket" {
  type        = string
  description = "Remote state bucket. Matches the backend block, which cannot use variables."
  default     = "trailmark-state-backend"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo allowed to assume these roles, as it appears in the token's sub claim"
  default     = "majidln@8521168/aws-saa-leaning-projects@1326414898"

  validation {
    condition     = can(regex("^[^/*]+/[^/*]+$", var.github_repo))
    error_message = "Must be exactly one owner/repo pair with no wildcard — a wildcard here would let other GitHub repos assume these roles."
  }
}