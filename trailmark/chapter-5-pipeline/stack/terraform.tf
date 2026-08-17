provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {
    bucket       = "trailmark-state-backend"
    key          = "chapter-5-pipeline/stack/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.60.0"
    }
  }

  required_version = "~> 1.15.8"
}
