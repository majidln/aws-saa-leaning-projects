variable "prefix" {
  type        = string
  description = "Prefix for resource names"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, prod) — applied as the Environment tag"
}

variable "single_nat_gateway" {
  type        = bool
  description = "Whether to create a single NAT Gateway for all AZs (true) or one per AZ (false)"
  default     = false
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to use"
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "The Trailmark network requires at least two Availability Zones."
  }
}