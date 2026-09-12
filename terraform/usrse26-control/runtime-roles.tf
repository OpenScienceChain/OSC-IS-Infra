data "aws_iam_policy_document" "runtime_eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runtime_ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "runtime_pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  runtime_pod_role_keys = toset([
    "alb-controller",
    "api-gateway",
    "postgres",
    "submission-worker",
    "submission-listener",
    "ledger-gateway-nsg",
    "ledger-gateway-citizen-science",
    "ebs-csi",
  ])

  runtime_secret_arn_patterns = {
    api_auth            = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/api/auth-*"
    listener_auth       = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/submission-listener/auth-*"
    demo_auth           = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/demo/auth-*"
    ledger_nsg_auth     = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/ledger/nsg/auth-*"
    ledger_citizen_auth = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/ledger/citizen-science/auth-*"
    postgres            = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/postgres-*"
    rabbitmq            = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/rabbitmq-*"
    fabric_nsg          = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/fabric/nsg-*"
    fabric_citizen      = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/fabric/citizen-science-*"
  }

  runtime_workload_secret_access = {
    api-gateway = [
      local.runtime_secret_arn_patterns.api_auth,
      local.runtime_secret_arn_patterns.listener_auth,
      local.runtime_secret_arn_patterns.demo_auth,
      local.runtime_secret_arn_patterns.postgres,
      local.runtime_secret_arn_patterns.rabbitmq,
    ]
    postgres = [local.runtime_secret_arn_patterns.postgres]
    submission-worker = [
      local.runtime_secret_arn_patterns.ledger_nsg_auth,
      local.runtime_secret_arn_patterns.ledger_citizen_auth,
      local.runtime_secret_arn_patterns.rabbitmq,
    ]
    submission-listener = [
      local.runtime_secret_arn_patterns.listener_auth,
      local.runtime_secret_arn_patterns.rabbitmq,
    ]
    ledger-gateway-nsg = [
      local.runtime_secret_arn_patterns.ledger_nsg_auth,
      local.runtime_secret_arn_patterns.fabric_nsg,
    ]
    ledger-gateway-citizen-science = [
      local.runtime_secret_arn_patterns.ledger_citizen_auth,
      local.runtime_secret_arn_patterns.fabric_citizen,
    ]
  }
}

resource "aws_iam_role" "runtime_eks_cluster" {
  name                 = "${local.name_prefix}-eks-cluster"
  assume_role_policy   = data.aws_iam_policy_document.runtime_eks_cluster_assume.json
  permissions_boundary = local.runtime_boundary_arn

  depends_on = [aws_iam_policy.lifecycle_boundary]
}

resource "aws_iam_role_policy_attachment" "runtime_eks_cluster" {
  role       = aws_iam_role.runtime_eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "runtime_eks_nodes" {
  name                 = "${local.name_prefix}-eks-nodes"
  assume_role_policy   = data.aws_iam_policy_document.runtime_ec2_assume.json
  permissions_boundary = local.runtime_boundary_arn

  depends_on = [aws_iam_policy.lifecycle_boundary]
}

resource "aws_iam_role_policy_attachment" "runtime_eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.runtime_eks_nodes.name
  policy_arn = each.value
}

resource "aws_iam_role" "runtime_pods" {
  for_each = local.runtime_pod_role_keys

  name                 = "${local.name_prefix}-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.runtime_pod_identity_assume.json
  permissions_boundary = local.runtime_boundary_arn

  depends_on = [aws_iam_policy.lifecycle_boundary]
}

resource "aws_iam_role_policy_attachment" "runtime_ebs_csi" {
  role       = aws_iam_role.runtime_pods["ebs-csi"].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "runtime_workload_secrets" {
  for_each = local.runtime_workload_secret_access

  name = "read-exact-osc-secrets"
  role = aws_iam_role.runtime_pods[each.key].id
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

resource "aws_iam_role_policy" "runtime_alb_controller" {
  name = "manage-tagged-internal-albs"
  role = aws_iam_role.runtime_pods["alb-controller"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateElasticLoadBalancingServiceRole"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Sid    = "ReadOnlyDiscovery"
        Effect = "Allow"
        Action = [
          "acm:DescribeCertificate", "acm:ListCertificates",
          "ec2:DescribeAccountAttributes", "ec2:DescribeAddresses", "ec2:DescribeAvailabilityZones",
          "ec2:DescribeCoipPools", "ec2:DescribeInstances", "ec2:DescribeInternetGateways",
          "ec2:DescribeIpamPools", "ec2:DescribeNetworkInterfaces", "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeTags",
          "ec2:DescribeVpcPeeringConnections", "ec2:DescribeVpcs", "ec2:GetCoipPoolUsage",
          "ec2:GetSecurityGroupsForVpc",
          "elasticloadbalancing:DescribeCapacityReservation", "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeListenerCertificates", "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancerAttributes", "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeTags", "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTrustStores", "iam:GetServerCertificate", "iam:ListServerCertificates",
          "shield:GetSubscriptionState", "shield:ListProtections", "waf-regional:GetWebACLForResource",
          "waf-regional:GetWebACL", "waf-regional:ListResourcesForWebACL", "waf-regional:ListWebACLs",
          "wafv2:GetWebACLForResource", "wafv2:GetWebACL", "wafv2:ListResourcesForWebACL",
          "wafv2:ListWebACLs",
        ]
        Resource = "*"
      },
      {
        Sid      = "CreateTaggedLoadBalancers"
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup", "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestTag/RunId"   = var.run_id
            "aws:RequestTag/Project" = "OSC-IS"
          }
        }
      },
      {
        Sid    = "ManageTaggedLoadBalancers"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:DeleteSecurityGroup", "ec2:RevokeSecurityGroupIngress",
          "ec2:CreateTags", "ec2:DeleteTags", "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteListener", "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule", "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyListenerAttributes", "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule", "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveTags", "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetRulePriorities", "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/RunId"   = var.run_id
            "aws:ResourceTag/Project" = "OSC-IS"
          }
        }
      },
    ]
  })
}
