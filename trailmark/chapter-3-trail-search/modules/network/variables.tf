variable "prefix" {
  type        = string
  description = "Prefix for resource names"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

