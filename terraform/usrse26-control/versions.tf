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

  default_tags { tags = local.required_tags }
}

# CloudFront ACM certificates and CLOUDFRONT-scope WAF resources are serviced
# from us-east-1 even though the application runtime remains in us-west-2.
provider "aws" {
  alias   = "edge"
  profile = var.aws_profile
  region  = "us-east-1"

  default_tags { tags = local.required_tags }
}

data "aws_caller_identity" "primary" {}
data "aws_caller_identity" "edge" { provider = aws.edge }
data "aws_region" "primary" {}

check "authorized_identity" {
  assert {
    condition = (
      data.aws_caller_identity.primary.account_id == "269624229733" &&
      data.aws_caller_identity.edge.account_id == "269624229733" &&
      data.aws_region.primary.region == "us-west-2"
    )
    error_message = "Refusing to manage the demo outside account 269624229733 and primary region us-west-2."
  }
}
