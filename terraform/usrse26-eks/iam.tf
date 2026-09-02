data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name               = "${local.name_prefix}-eks-nodes"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  workload_secret_access = {
    api-gateway = [
      aws_secretsmanager_secret.application.arn,
      aws_secretsmanager_secret.postgres.arn,
      aws_secretsmanager_secret.rabbitmq.arn,
    ]
    postgres = [aws_secretsmanager_secret.postgres.arn]
    submission-worker = [
      aws_secretsmanager_secret.application.arn,
      aws_secretsmanager_secret.rabbitmq.arn,
    ]
    submission-listener = [
      aws_secretsmanager_secret.application.arn,
      aws_secretsmanager_secret.rabbitmq.arn,
    ]
    ledger-gateway-nsg = [
      aws_secretsmanager_secret.application.arn,
      aws_secretsmanager_secret.fabric_nsg.arn,
    ]
    ledger-gateway-citizen-science = [
      aws_secretsmanager_secret.application.arn,
      aws_secretsmanager_secret.fabric_citizen_science.arn,
    ]
  }
}

resource "aws_iam_role" "workload_secrets" {
  for_each = local.workload_secret_access

  name               = "${local.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "workload_secrets" {
  for_each = local.workload_secret_access

  name = "read-exact-osc-secrets"
  role = aws_iam_role.workload_secrets[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadExactSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = each.value
    }]
  })
}

resource "aws_eks_pod_identity_association" "workload_secrets" {
  for_each = local.workload_secret_access

  cluster_name    = aws_eks_cluster.experiment.name
  namespace       = "osc-apps"
  service_account = each.key
  role_arn        = aws_iam_role.workload_secrets[each.key].arn

  depends_on = [aws_eks_addon.pod_identity]
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = aws_eks_cluster.experiment.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  depends_on = [aws_eks_addon.pod_identity]
}
