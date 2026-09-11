resource "aws_s3_bucket" "control" {
  #checkov:skip=CKV_AWS_18: The private control bucket is not an HTTP origin; lifecycle and state-machine logs provide the audit trail.
  #checkov:skip=CKV_AWS_144: The authorized experiment is single-region us-west-2 and must leave zero cross-region residuals.
  #checkov:skip=CKV_AWS_145: AES256 encryption avoids a customer-managed KMS key whose deletion window would outlive teardown.
  #checkov:skip=CKV2_AWS_62: Evidence, security logs, and Terraform state are written by explicit lifecycle actions, not event processing.
  bucket        = "${local.name_prefix}-control-${var.authorized_account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "control" {
  bucket                  = aws_s3_bucket.control.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "control" {
  bucket = aws_s3_bucket.control.id
  rule {
    blocked_encryption_types = ["SSE-C"]
    bucket_key_enabled       = false
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "control" {
  bucket = aws_s3_bucket.control.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "control" {
  #checkov:skip=CKV_AWS_300: Every lifecycle rule has a one-day abort policy; Checkov 3.3.9 misreports the third rule.
  bucket = aws_s3_bucket.control.id
  rule {
    id     = "expire-sanitized-evidence"
    status = "Enabled"
    filter { prefix = "evidence/" }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
  rule {
    id     = "expire-security-logs"
    status = "Enabled"
    filter { prefix = "security-logs/" }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
  rule {
    id     = "expire-runtime-state"
    status = "Enabled"
    filter { prefix = "runtime-state/" }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_dynamodb_table" "lifecycle" {
  #checkov:skip=CKV_AWS_119: AWS-owned encryption avoids a KMS key whose deletion window would violate zero-residual teardown.
  name         = "${local.name_prefix}-lifecycle"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "runId"
  attribute {
    name = "runId"
    type = "S"
  }
  ttl {
    attribute_name = "expiresAtEpoch"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
}

resource "aws_dynamodb_table" "terraform_locks" {
  #checkov:skip=CKV_AWS_119: AWS-owned encryption avoids a KMS key whose deletion window would violate zero-residual teardown.
  name         = "${local.name_prefix}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  point_in_time_recovery { enabled = true }
  server_side_encryption { enabled = true }
}

resource "aws_sns_topic" "lifecycle" {
  name              = "${local.name_prefix}-notifications"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == null ? 0 : 1
  topic_arn = aws_sns_topic.lifecycle.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${local.name_prefix}-scheduler-dlq"
  message_retention_seconds = 604800
  sqs_managed_sse_enabled   = true
}

resource "aws_cloudwatch_log_group" "lifecycle" {
  #checkov:skip=CKV_AWS_158: AWS-owned encryption avoids a KMS key whose deletion window would violate zero-residual teardown.
  #checkov:skip=CKV_AWS_338: Seven-day retention is proportionate for a disposable demo capped at 72 hours.
  name              = "/aws/codebuild/${local.name_prefix}-lifecycle"
  retention_in_days = 7
}

# The lifecycle image is prepared and pushed before this control plane exists.
# Importing this exact run-scoped repository makes the surviving backup-stop
# dependency part of the control plane and removes it only during final control
# teardown, after runtime teardown evidence has passed.
resource "aws_ecr_repository" "lifecycle_runner" {
  #checkov:skip=CKV_AWS_136: AES256 encryption avoids a customer-managed KMS key whose deletion window would outlive teardown.
  name                 = "${local.name_prefix}/lifecycle-runner"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "lifecycle_runner" {
  repository = aws_ecr_repository.lifecycle_runner.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain only the five most recent control images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

locals {
  runtime_boundary_arn = "arn:aws:iam::${var.authorized_account_id}:policy/${local.name_prefix}-runtime-boundary"
  runtime_role_arn_map = {
    eks_cluster                    = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-eks-cluster"
    eks_nodes                      = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-eks-nodes"
    alb_controller                 = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-alb-controller"
    api_gateway                    = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-api-gateway"
    postgres                       = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-postgres"
    submission_worker              = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-submission-worker"
    submission_listener            = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-submission-listener"
    ledger_gateway_nsg             = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-ledger-gateway-nsg"
    ledger_gateway_citizen_science = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-ledger-gateway-citizen-science"
    ebs_csi                        = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-ebs-csi"
  }
  runtime_passed_to_services = [
    "ec2.amazonaws.com",
    "eks.amazonaws.com",
    "pods.eks.amazonaws.com",
  ]
  runtime_iam_statements = [
    {
      Sid      = "PassOnlyRunRolesToApprovedServices"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = values(local.runtime_role_arn_map)
      Condition = {
        StringEquals = {
          "iam:PassedToService" = local.runtime_passed_to_services
        }
      }
    },
    {
      Sid      = "CreateOnlyRequiredServiceLinkedRoles"
      Effect   = "Allow"
      Action   = ["iam:CreateServiceLinkedRole"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "iam:AWSServiceName" = [
            "autoscaling.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "eks.amazonaws.com",
            "mq.amazonaws.com",
          ]
        }
      }
    },
  ]
  runtime_service_statements = [
    {
      Sid    = "ReadOnlyRuntimeDiscovery"
      Effect = "Allow"
      Action = [
        "acm:DescribeCertificate", "acm:ListCertificates", "autoscaling:Describe*",
        "cloudfront:ListVpcOrigins",
        "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "ec2:Describe*",
        "ec2:GetCoipPoolUsage", "ec2:GetSecurityGroupsForVpc", "ecr:GetAuthorizationToken",
        "eks:List*", "elasticloadbalancing:Describe*",
        "logs:DescribeLogGroups", "mq:List*", "resourcegroupstaggingapi:GetResources",
        "iam:GetServerCertificate", "iam:ListServerCertificates", "shield:GetSubscriptionState", "shield:ListProtections", "sts:GetCallerIdentity",
        "waf-regional:Get*", "waf-regional:List*", "wafv2:Get*", "wafv2:List*",
      ]
      Resource = "*"
    },
    {
      Sid    = "ExactRunS3Buckets"
      Effect = "Allow"
      Action = ["s3:GetBucketVersioning", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}",
        "arn:aws:s3:::${local.name_prefix}-edge-${var.authorized_account_id}",
      ]
    },
    {
      Sid    = "ExactRunS3Objects"
      Effect = "Allow"
      Action = ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
      Resource = [
        "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}/artifacts/${var.run_id}/*",
        "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}/evidence/${var.run_id}/*",
        "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}/runtime-state/${var.run_id}/*",
        "arn:aws:s3:::${local.name_prefix}-control-${var.authorized_account_id}/security-logs/${var.run_id}/*",
        "arn:aws:s3:::${local.name_prefix}-edge-${var.authorized_account_id}/*",
        "arn:aws:s3:::${local.artifact_manifest_bucket}/${local.artifact_manifest_prefix}/*",
      ]
    },
    {
      Sid      = "ExactRunSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:TagResource"]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.authorized_account_id}:secret:${local.name_prefix}/*"
    },
    {
      Sid      = "CreateNamedRunSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:CreateSecret"]
      Resource = "*"
      Condition = {
        StringLike = { "secretsmanager:Name" = "${local.name_prefix}/*" }
        StringEquals = {
          "aws:RequestTag/Project" = "OSC-IS"
          "aws:RequestTag/RunId"   = var.run_id
        }
      }
    },
    {
      Sid      = "ExactRunEcrRepositories"
      Effect   = "Allow"
      Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload", "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DeleteRepositoryPolicy", "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:GetDownloadUrlForLayer", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:InitiateLayerUpload", "ecr:ListImages", "ecr:ListTagsForResource", "ecr:PutImage", "ecr:PutLifecyclePolicy", "ecr:SetRepositoryPolicy", "ecr:TagResource", "ecr:UntagResource", "ecr:UploadLayerPart"]
      Resource = "arn:aws:ecr:${var.aws_region}:${var.authorized_account_id}:repository/${local.name_prefix}/*"
    },
    {
      Sid    = "ExactRunDynamoTables"
      Effect = "Allow"
      Action = ["dynamodb:DeleteItem", "dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
      Resource = [
        "arn:aws:dynamodb:${var.aws_region}:${var.authorized_account_id}:table/${local.name_prefix}-lifecycle",
        "arn:aws:dynamodb:${var.aws_region}:${var.authorized_account_id}:table/${local.name_prefix}-terraform-locks",
      ]
    },
    {
      Sid      = "ExactRunCloudFormation"
      Effect   = "Allow"
      Action   = ["cloudformation:*Stack*", "cloudformation:GetTemplate", "cloudformation:GetTemplateSummary", "cloudformation:ListStackResources", "cloudformation:TagResource", "cloudformation:UntagResource"]
      Resource = "arn:aws:cloudformation:${var.aws_region}:${var.authorized_account_id}:stack/${local.name_prefix}-*/*"
    },
    {
      Sid    = "ExactRunEks"
      Effect = "Allow"
      Action = ["eks:Associate*", "eks:Create*", "eks:Delete*", "eks:Describe*", "eks:Disassociate*", "eks:TagResource", "eks:UntagResource", "eks:Update*"]
      Resource = [
        "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:cluster/${local.name_prefix}-*",
        "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:nodegroup/${local.name_prefix}-*/*/*",
        "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:addon/${local.name_prefix}-*/*/*",
        "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:podidentityassociation/${local.name_prefix}-*/*",
      ]
    },
    {
      Sid    = "ExactRunMq"
      Effect = "Allow"
      Action = ["mq:Create*", "mq:Delete*", "mq:Describe*", "mq:RebootBroker", "mq:TagResource", "mq:UntagResource", "mq:Update*"]
      Resource = [
        "arn:aws:mq:${var.aws_region}:${var.authorized_account_id}:broker:${local.name_prefix}-*:*",
        "arn:aws:mq:${var.aws_region}:${var.authorized_account_id}:configuration:${local.name_prefix}-*:*",
      ]
    },
    {
      Sid      = "CreateTaggedNetworkResources"
      Effect   = "Allow"
      Action   = ["ec2:AllocateAddress", "ec2:Create*", "elasticloadbalancing:Create*"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:RequestTag/Project" = "OSC-IS"
          "aws:RequestTag/RunId"   = var.run_id
        }
      }
    },
    {
      Sid      = "ManageTaggedNetworkResources"
      Effect   = "Allow"
      Action   = ["ec2:Associate*", "ec2:Attach*", "ec2:Authorize*", "ec2:CreateRoute", "ec2:CreateTags", "ec2:Delete*", "ec2:Detach*", "ec2:Disassociate*", "ec2:Modify*", "ec2:ReleaseAddress", "ec2:Revoke*", "elasticloadbalancing:AddTags", "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateRule", "elasticloadbalancing:Delete*", "elasticloadbalancing:DeregisterTargets", "elasticloadbalancing:Modify*", "elasticloadbalancing:RegisterTargets", "elasticloadbalancing:RemoveTags", "elasticloadbalancing:Set*"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/Project" = "OSC-IS"
          "aws:ResourceTag/RunId"   = var.run_id
        }
      }
    },
    {
      Sid      = "ExactRunLogs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy"]
      Resource = "arn:aws:logs:${var.aws_region}:${var.authorized_account_id}:log-group:/aws/eks/${local.name_prefix}-*"
    },
    {
      Sid    = "ExactControlOperations"
      Effect = "Allow"
      Action = ["codebuild:UpdateProject", "sns:Publish", "states:StartExecution"]
      Resource = [
        "arn:aws:codebuild:${var.aws_region}:${var.authorized_account_id}:project/${local.name_prefix}-lifecycle",
        "arn:aws:codebuild:${var.aws_region}:${var.authorized_account_id}:project/${local.name_prefix}-cleanup",
        "arn:aws:sns:${var.aws_region}:${var.authorized_account_id}:${local.name_prefix}-notifications",
        "arn:aws:states:${var.aws_region}:${var.authorized_account_id}:stateMachine:${local.name_prefix}-stop",
      ]
    },
    {
      Sid      = "CreateTaggedCloudFrontRuntimeOrigin"
      Effect   = "Allow"
      Action   = ["cloudfront:CreateVpcOrigin"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:RequestTag/RunId" = var.run_id
        }
      }
    },
    {
      Sid      = "DeleteTaggedCloudFrontRuntimeOrigin"
      Effect   = "Allow"
      Action   = ["cloudfront:DeleteVpcOrigin"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/RunId" = var.run_id
        }
      }
    },
    {
      Sid      = "ReadTaggedCloudFrontResources"
      Effect   = "Allow"
      Action   = ["cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:GetVpcOrigin"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/RunId" = var.run_id
        }
      }
    },
    {
      Sid      = "UpdateTaggedControlDistribution"
      Effect   = "Allow"
      Action   = ["cloudfront:UpdateDistribution"]
      Resource = "*"
      Condition = {
        StringEquals = {
          "aws:ResourceTag/RunId" = var.run_id
        }
      }
    },
  ]
  runtime_workload_boundary_statements = [
    {
      Sid    = "EksSystemImagePull"
      Effect = "Allow"
      Action = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = [
        "arn:aws:ecr:${var.aws_region}:602401143452:repository/amazon/aws-network-policy-agent",
        "arn:aws:ecr:${var.aws_region}:602401143452:repository/amazon-k8s-cni*",
        "arn:aws:ecr:${var.aws_region}:602401143452:repository/eks/*",
      ]
    },
    {
      Sid    = "EksNodeCniBootstrap"
      Effect = "Allow"
      Action = [
        "ec2:AssignIpv6Addresses", "ec2:AssignPrivateIpAddresses", "ec2:AttachNetworkInterface",
        "ec2:CreateNetworkInterface", "ec2:CreateTags", "ec2:DeleteNetworkInterface", "ec2:DetachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute", "ec2:UnassignIpv6Addresses", "ec2:UnassignPrivateIpAddresses",
      ]
      Resource = "*"
    },
    {
      Sid      = "EksPodIdentityAgent"
      Effect   = "Allow"
      Action   = ["eks-auth:AssumeRoleForPodIdentity"]
      Resource = "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:cluster/${local.name_prefix}-*"
    },
  ]

  # AWS caps a managed policy at 6,144 non-whitespace characters. Keep the
  # lifecycle role's exact grants below as the identity policy, while making
  # this shared boundary a compact, immutable run-scoped ceiling. Statement
  # IDs have no authorization semantics. The merged statements have identical
  # conditions, and every shortened ARN remains anchored to the exact run ID.
  # PassRole is broader only in the ceiling: the intersecting identity policy
  # continues to enumerate every fixed role and the runner cannot create or
  # mutate roles.
  runtime_boundary_statement_inputs = concat(
    local.runtime_service_statements,
    local.runtime_workload_boundary_statements,
    local.runtime_iam_statements,
  )
  runtime_boundary_statement_by_sid = {
    for statement in local.runtime_boundary_statement_inputs : statement.Sid => statement
  }
  runtime_boundary_merged_sids = [
    "ExactRunS3Objects",
    "DeleteTaggedCloudFrontRuntimeOrigin",
    "UpdateTaggedControlDistribution",
    "EksPodIdentityAgent",
  ]
  runtime_boundary_action_overrides = {
    ExactRunS3Buckets = concat(
      local.runtime_boundary_statement_by_sid["ExactRunS3Buckets"].Action,
      local.runtime_boundary_statement_by_sid["ExactRunS3Objects"].Action,
    )
    ExactRunEks = concat(
      local.runtime_boundary_statement_by_sid["ExactRunEks"].Action,
      local.runtime_boundary_statement_by_sid["EksPodIdentityAgent"].Action,
    )
    ReadTaggedCloudFrontResources = concat(
      local.runtime_boundary_statement_by_sid["DeleteTaggedCloudFrontRuntimeOrigin"].Action,
      local.runtime_boundary_statement_by_sid["ReadTaggedCloudFrontResources"].Action,
      local.runtime_boundary_statement_by_sid["UpdateTaggedControlDistribution"].Action,
    )
  }
  runtime_boundary_resource_overrides = {
    ExactRunS3Buckets = [
      "arn:aws:s3:::${local.name_prefix}-*",
      "arn:aws:s3:::${local.name_prefix}-*/*",
      "arn:aws:s3:::${local.artifact_manifest_bucket}/${local.artifact_manifest_prefix}/*",
    ]
    ExactRunDynamoTables = [
      "arn:aws:dynamodb:${var.aws_region}:${var.authorized_account_id}:table/${local.name_prefix}-*",
    ]
    ExactRunEks = [
      "arn:aws:eks:${var.aws_region}:${var.authorized_account_id}:*/${local.name_prefix}-*",
    ]
    ExactRunMq = [
      "arn:aws:mq:${var.aws_region}:${var.authorized_account_id}:*:${local.name_prefix}-*:*",
    ]
    ExactControlOperations = [
      "arn:aws:codebuild:${var.aws_region}:${var.authorized_account_id}:project/${local.name_prefix}-*",
      "arn:aws:sns:${var.aws_region}:${var.authorized_account_id}:${local.name_prefix}-notifications",
      "arn:aws:states:${var.aws_region}:${var.authorized_account_id}:stateMachine:${local.name_prefix}-stop",
    ]
    PassOnlyRunRolesToApprovedServices = [
      "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-*",
    ]
  }
  lifecycle_boundary_policy = {
    Version = "2012-10-17"
    Statement = [
      for statement in local.runtime_boundary_statement_inputs : merge(
        { for key, value in statement : key => value if key != "Sid" },
        {
          Action = try(local.runtime_boundary_action_overrides[statement.Sid], statement.Action)
          Resource = try(
            local.runtime_boundary_resource_overrides[statement.Sid],
            tolist(statement.Resource),
            [statement.Resource],
          )
        },
      ) if !contains(local.runtime_boundary_merged_sids, statement.Sid)
    ]
  }
  lifecycle_role_policy = {
    Version   = "2012-10-17"
    Statement = concat(local.runtime_service_statements, local.runtime_iam_statements)
  }
}

resource "aws_iam_policy" "lifecycle_boundary" {
  #checkov:skip=CKV_AWS_286: Credential reads are limited to exact run-scoped secret ARNs; no IAM credential creation is allowed.
  #checkov:skip=CKV_AWS_287: IAM is limited to exact-role PassRole and four allowlisted service-linked roles; role and policy mutation are absent.
  #checkov:skip=CKV_AWS_288: Runtime data APIs are restricted to exact run/control ARNs or mandatory run tags.
  #checkov:skip=CKV_AWS_290: Wildcard action patterns are limited to named run resources, tag-conditioned infrastructure, and read-only discovery.
  #checkov:skip=CKV_AWS_355: Resource=* remains only for read-only discovery, tag-conditioned operations, ECR authorization, and EKS CNI bootstrap.
  name        = "${local.name_prefix}-runtime-boundary"
  description = "Immutable permission ceiling for the lifecycle runner and every disposable runtime role"
  policy      = jsonencode(local.lifecycle_boundary_policy)

  lifecycle {
    precondition {
      condition     = length(jsonencode(local.lifecycle_boundary_policy)) <= 6144
      error_message = "The runtime permissions boundary exceeds AWS IAM's 6,144-character managed-policy quota."
    }
  }
}

resource "aws_iam_role" "lifecycle" {
  name                 = "${local.name_prefix}-lifecycle"
  assume_role_policy   = data.aws_iam_policy_document.codebuild_assume.json
  permissions_boundary = local.runtime_boundary_arn

  depends_on = [aws_iam_policy.lifecycle_boundary]
}

resource "aws_iam_role_policy" "lifecycle" {
  #checkov:skip=CKV_AWS_355: Resource=* is limited to read-only discovery, tagged creation/management, ECR authorization, and exact service-linked-role creation; the run boundary intersects every grant.
  name   = "bounded-demo-lifecycle"
  role   = aws_iam_role.lifecycle.id
  policy = jsonencode(local.lifecycle_role_policy)
}

resource "aws_codebuild_project" "lifecycle" {
  name           = "${local.name_prefix}-lifecycle"
  service_role   = aws_iam_role.lifecycle.arn
  build_timeout  = 120
  queued_timeout = 15

  artifacts { type = "NO_ARTIFACTS" }
  source {
    type = "NO_SOURCE"
    buildspec = yamlencode({
      version = 0.2
      phases = {
        pre_build = { commands = [
          "test \"$(aws sts get-caller-identity --query Account --output text)\" = \"$EXPECTED_ACCOUNT_ID\"",
          "test \"$AWS_DEFAULT_REGION\" = \"$EXPECTED_REGION\"",
          "test \"$COST_CONTROL_MODE\" = \"TIME_BOUNDED\""
        ] }
        build = { commands = ["CODEBUILD_PROJECT=\"$LIFECYCLE_CODEBUILD_PROJECT\" /usr/local/bin/osc-demo-lifecycle \"$ACTION\""] }
      }
    })
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.lifecycle_runner_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    dynamic "environment_variable" {
      for_each = merge(local.lifecycle_environment, { PLANNING_ESTIMATE_USD = tostring(var.planning_estimate_usd) })
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "PLAINTEXT"
      }
    }
  }
  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.lifecycle.name
      stream_name = var.run_id
    }
  }
}

# This project is never attached to the disposable VPC. It remains able to
# destroy Terraform state and verify the tag inventory even when an in-VPC
# lifecycle action or network reset fails.
resource "aws_codebuild_project" "cleanup" {
  name           = "${local.name_prefix}-cleanup"
  service_role   = aws_iam_role.lifecycle.arn
  build_timeout  = 120
  queued_timeout = 15

  artifacts { type = "NO_ARTIFACTS" }
  source {
    type = "NO_SOURCE"
    buildspec = yamlencode({
      version = 0.2
      phases = {
        pre_build = { commands = [
          "test \"$(aws sts get-caller-identity --query Account --output text)\" = \"$EXPECTED_ACCOUNT_ID\"",
          "test \"$AWS_DEFAULT_REGION\" = \"$EXPECTED_REGION\"",
          "test \"$ACTION\" = \"DESTROY_RUNTIME\" -o \"$ACTION\" = \"SWEEP\""
        ] }
        build = { commands = ["CODEBUILD_PROJECT=\"$LIFECYCLE_CODEBUILD_PROJECT\" /usr/local/bin/osc-demo-lifecycle \"$ACTION\""] }
      }
    })
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.lifecycle_runner_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    dynamic "environment_variable" {
      for_each = merge(local.lifecycle_environment, { PLANNING_ESTIMATE_USD = tostring(var.planning_estimate_usd) })
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "PLAINTEXT"
      }
    }
  }
  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.lifecycle.name
      stream_name = "${var.run_id}-cleanup"
    }
  }
}
