provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "gatekeeper"
    }
  }
}

provider "auth0" {
  domain        = var.auth0_domain
  client_id     = var.auth0_client_id
  client_secret = var.auth0_client_secret
}