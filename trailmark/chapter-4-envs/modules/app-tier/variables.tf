variable "prefix" {
  type        = string
  description = "Prefix for resource names"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID"
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the app tier"
  default     = "t3.micro"
}

variable "app_port" {
  type        = number
  description = "Port for the app tier"
  default     = 8080
}

variable "db_secret_arn" {
  type        = string
  description = "ARN of the Secrets Manager secret with DB credentials"
}

variable "asg_min_size" {
  type        = number
  description = "Minimum number of app instances"
  default     = 1
}

variable "asg_max_size" {
  type        = number
  description = "Maximum number of app instances"
  default     = 4
}

variable "asg_desired_capacity" {
  type        = number
  description = "Desired number of app instances"
  default     = 1
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. dev, prod) — applied as the Environment tag"
}