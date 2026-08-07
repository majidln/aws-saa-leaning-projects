variable "region" {
  type    = string
  default = "us-east-1"
}

variable "bucket" {
  type    = string
  default = "trailmark-chapter-2-cdn-https-frontend"
}

variable "bucket_name" {
  type    = string
  default = "Trailmark Chapter 2: CDN and HTTPS Frontend"
}

variable "state-bucket" {
  type    = string
  default = "trailmark-state-backend"
}