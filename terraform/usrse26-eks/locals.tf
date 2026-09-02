locals {
  name_prefix  = "osc-usrse26-${var.run_id}"
  cluster_name = "${local.name_prefix}-eks"

  required_tags = {
    Project     = "OSC-IS"
    Purpose     = "USRSE26-Evidence"
    Environment = "ephemeral"
    ManagedBy   = "Terraform"
    Owner       = "ofgarzon"
    RunId       = var.run_id
    ExpiresAt   = var.expires_at
  }

  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  addon_versions = {
    kube-proxy                            = "v1.35.3-eksbuild.21"
    vpc-cni                               = "v1.23.0-eksbuild.1"
    coredns                               = "v1.14.3-eksbuild.14"
    eks-pod-identity-agent                = "v1.4.0-eksbuild.1"
    aws-ebs-csi-driver                    = "v1.65.0-eksbuild.1"
    aws-secrets-store-csi-driver-provider = "v3.1.3-eksbuild.1"
  }

  ecr_repositories = toset([
    "api-gateway",
    "ledger-gateway",
    "submission-worker",
    "submission-listener",
    "chaincode",
    "gitops-repository",
  ])
}
