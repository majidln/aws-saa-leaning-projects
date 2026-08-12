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