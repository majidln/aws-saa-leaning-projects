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

variable "state_bucket" {
  type        = string
  description = "Remote state bucket. Matches the backend block, which cannot use variables."
  default     = "trailmark-state-backend"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository allowed to assume these roles, as owner/name"
  default     = "majidln/aws-saa-leaning-projects"

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "Must be exactly owner/name — a wildcard here would let any GitHub repo assume these roles."
  }
}