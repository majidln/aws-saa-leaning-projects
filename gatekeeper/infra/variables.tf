variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for Lambda log groups"
  type        = number
  default     = 7
}

variable "stage_name" {
  description = "API Gateway stage name — also the URL path segment (.../<stage_name>/hello). Override with TF_VAR_stage_name."
  type        = string
  default     = "dev"
}
