terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket       = "osc-is-terraform-state"
    key          = "osc-fabric-test/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "OSC-IS"
      Environment = "fabric-test"
      ManagedBy   = "Terraform"
      Ephemeral   = "true"
    }
  }
}
