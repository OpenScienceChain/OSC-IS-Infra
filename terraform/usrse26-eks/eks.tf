resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "experiment" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.admin_cidr]
  }

  depends_on = [
    aws_cloudwatch_log_group.eks,
    aws_iam_role_policy_attachment.eks_cluster,
    aws_route.private_internet,
  ]
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.name_prefix}-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_size           = 40
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.required_tags, { Name = "${local.name_prefix}-eks-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.required_tags, { Name = "${local.name_prefix}-eks-node" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "experiment" {
  cluster_name    = aws_eks_cluster.experiment.name
  node_group_name = "${local.name_prefix}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  instance_types  = var.node_instance_types
  version         = var.kubernetes_version

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = var.node_count
    min_size     = var.node_count
    max_size     = var.node_count
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_versions["vpc-cni"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_versions["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "coredns"
  addon_version               = local.addon_versions["coredns"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.experiment]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = local.addon_versions["eks-pod-identity-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.experiment]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = local.addon_versions["aws-ebs-csi-driver"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [
    aws_eks_node_group.experiment,
    aws_eks_pod_identity_association.ebs_csi,
  ]
}

resource "aws_eks_addon" "secrets_store" {
  cluster_name                = aws_eks_cluster.experiment.name
  addon_name                  = "aws-secrets-store-csi-driver-provider"
  addon_version               = local.addon_versions["aws-secrets-store-csi-driver-provider"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  configuration_values = jsonencode({
    awsRegion = var.aws_region
    secrets-store-csi-driver = {
      syncSecret           = { enabled = true }
      enableSecretRotation = true
      rotationPollInterval = "2m"
    }
  })

  depends_on = [
    aws_eks_node_group.experiment,
    aws_eks_addon.pod_identity,
  ]
}
