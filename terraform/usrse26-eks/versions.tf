terraform {
  required_version = ">= 1.14.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.36.0"
    }
  }
}

provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = local.required_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

check "authorized_account" {
  assert {
    condition     = data.aws_caller_identity.current.account_id == var.authorized_account_id
    error_message = "Refusing to operate outside the authorized OSC-IS AWS account."
  }
}
