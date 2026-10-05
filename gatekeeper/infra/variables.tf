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

variable "authorizer_cache_ttl" {
  description = "Seconds API Gateway caches an authorizer decision (Allow and Deny alike), keyed by the Authorization header. 0 disables caching; max 3600."
  type        = number
  default     = 300
}

variable "stage_name" {
  description = "API Gateway stage name — also the URL path segment (.../<stage_name>/hello). Override with TF_VAR_stage_name."
  type        = string
  default     = "dev"
}

variable "auth0_domain" {
  description = "Auth0 tenant domain, no scheme and no trailing slash (e.g. dev-abc123.eu.auth0.com). Set with TF_VAR_auth0_domain."
  type        = string
}

variable "auth0_audience" {
  description = "API identifier registered in Auth0. Becomes the token's aud claim."
  type        = string
  default     = "https://gatekeeper/api"
}

# Credentials for the terraform-gatekeeper M2M app (Management API, actions scopes only).
# Not tenant-a/tenant-b: those mint tokens for the API and can't manage Auth0.
# No defaults on purpose — Terraform stops and asks rather than using a wrong identity.
variable "auth0_client_id" {
  description = "Client ID of the Auth0 app Terraform manages config with. Set with TF_VAR_auth0_client_id."
  type        = string
}

variable "auth0_client_secret" {
  description = "Its client secret. Set with TF_VAR_auth0_client_secret, never in a file."
  type        = string
  sensitive   = true
}
