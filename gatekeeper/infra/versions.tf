terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    auth0 = {
      source  = "auth0/auth0"
      version = "~> 1.36"
    }
  }

  backend "s3" {
    bucket       = "gatekeeper-sample-project"
    key          = "gatekeeper/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
