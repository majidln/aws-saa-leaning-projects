provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {
    bucket = "trailmark-state-backend"
    key    = "chapter-2-cdn-https/terraform.tfstate"
    region = "us-east-1"
    use_lockfile = true
  }
  required_providers {
    aws = {
      version = "~> 5.52.0"
    }
  }

  required_version = "~> 1.15.8"
}
