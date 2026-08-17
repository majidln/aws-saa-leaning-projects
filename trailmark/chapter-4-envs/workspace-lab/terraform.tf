provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {
    bucket       = "trailmark-state-backend"
    key          = "chapter-4-envs/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.52.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  required_version = "~> 1.15.8"
}
