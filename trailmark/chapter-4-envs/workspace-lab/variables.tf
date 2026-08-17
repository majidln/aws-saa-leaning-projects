variable "prefix" {
  type        = string
  description = "Prefix for resource names"
}

variable "region" {
  type = string
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type for the app tier"
}

variable "app_port" {
  type        = number
  description = "Port for the application"
}

variable "db_port" {
  type        = number
  description = "Port for the database"
}

variable "asg_min_size" {
  type        = number
  description = "Minimum number of app instances"
}

variable "asg_max_size" {
  type        = number
  description = "Maximum number of app instances"
}

variable "asg_desired_capacity" {
  type        = number
  description = "Desired number of app instances"
}

variable "single_nat_gateway" {
  type        = bool
  description = "Share one NAT Gateway across all app subnets instead of one per AZ"
}

variable "recovery_window_in_days" {
  type        = number
  description = "The number of days that Secrets Manager waits before it can delete the secret. You can specify a value from 7 to 30 days."
  default     = 30
}

variable "db_instance_class" {
  type        = string
  description = "RDS instance class for the database"
}