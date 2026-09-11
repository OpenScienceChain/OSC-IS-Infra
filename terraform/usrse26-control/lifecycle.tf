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
  runtime_boundary_arn     = "arn:aws:iam::${var.authorized_account_id}:policy/${local.name_prefix}-runtime-boundary"
  runtime_role_arn_pattern = "arn:aws:iam::${var.authorized_account_id}:role/${local.name_prefix}-*"
  runtime_oidc_arn_pattern = "arn:aws:iam::${var.authorized_account_id}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/*"
  runtime_managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]
  runtime_passed_to_services = [
    "ec2.amazonaws.com",
    "eks.amazonaws.com",
    "pods.eks.amazonaws.com",
  ]
  runtime_iam_statements = [
    {
      Sid      = "CreateOnlyBoundedRuntimeRoles"
      Effect   = "Allow"
      Action   = ["iam:CreateRole"]
      Resource = local.runtime_role_arn_pattern
      Condition = {
        StringEquals = {
          "iam:PermissionsBoundary"    = local.runtime_boundary_arn
          "aws:RequestTag/Project"     = "OSC-IS"
          "aws:RequestTag/Purpose"     = "USRSE26-Interactive-Demo"
          "aws:RequestTag/Environment" = "ephemeral"
          "aws:RequestTag/RunId"       = var.run_id
        }
      }
    },
    {
      Sid    = "ManageOnlyRunPrefixedRoles"
      Effect = "Allow"
      Action = [
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListRolePolicies",
        "iam:PutRolePolicy",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:UpdateAssumeRolePolicy",
      ]
      Resource = local.runtime_role_arn_pattern
    },
    {
      Sid      = "AttachOnlyApprovedManagedPolicies"
      Effect   = "Allow"
      Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
      Resource = local.runtime_role_arn_pattern
      Condition = {
        ArnEquals = {
          "iam:PolicyARN" = local.runtime_managed_policy_arns
        }
      }
    },
    {
      Sid      = "ReadOnlyApprovedManagedPolicies"
      Effect   = "Allow"
      Action   = ["iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions"]
      Resource = local.runtime_managed_policy_arns
    },
    {
      Sid      = "PassOnlyRunRolesToApprovedServices"
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = local.runtime_role_arn_pattern
      Condition = {
        StringEquals = {
          "iam:PassedToService" = local.runtime_passed_to_services
        }
      }
    },
    {
      Sid      = "ManageOnlyRegionalEksOidcProvider"
      Effect   = "Allow"
      Action   = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider"]
      Resource = local.runtime_oidc_arn_pattern
    },
    {
      Sid      = "ListOidcProviders"
      Effect   = "Allow"
      Action   = ["iam:ListOpenIDConnectProviders"]
      Resource = "*"
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
  lifecycle_boundary_policy = {
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "RuntimeAndControlServices"
        Effect = "Allow"
        Action = [
          "autoscaling:*", "budgets:ViewBudget", "cloudformation:*", "cloudfront:*",
          "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "codebuild:UpdateProject",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
          "ec2:*", "ecr:*", "eks:*", "elasticloadbalancing:*",
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups", "logs:PutRetentionPolicy",
          "mq:*", "resourcegroupstaggingapi:GetResources", "s3:*", "secretsmanager:*", "sns:Publish",
          "states:StartExecution", "sts:GetCallerIdentity",
        ]
        Resource = "*"
      },
    ], local.runtime_iam_statements)
  }
}

resource "aws_iam_policy" "lifecycle_boundary" {
  #checkov:skip=CKV_AWS_286: The boundary permits credential APIs only for the disposable runtime; exact role policy and run ownership checks are narrower.
  #checkov:skip=CKV_AWS_287: The boundary is the maximum runtime service surface; exact role policy and run ownership checks are narrower.
  #checkov:skip=CKV_AWS_288: The boundary permits disposable runtime data APIs; exact role policy and run ownership checks are narrower.
  #checkov:skip=CKV_AWS_290: Service wildcards exclude IAM and are intersected with the narrower lifecycle role policy.
  #checkov:skip=CKV_AWS_355: Resource=* is limited to non-IAM runtime services and APIs that do not support resource scoping.
  name        = "${local.name_prefix}-runtime-boundary"
  description = "Immutable permission ceiling for the lifecycle runner and every disposable runtime role"
  policy      = jsonencode(local.lifecycle_boundary_policy)
}

resource "aws_iam_role" "lifecycle" {
  name                 = "${local.name_prefix}-lifecycle"
  assume_role_policy   = data.aws_iam_policy_document.codebuild_assume.json
  permissions_boundary = aws_iam_policy.lifecycle_boundary.arn
}

resource "aws_iam_role_policy" "lifecycle" {
  name = "bounded-demo-lifecycle"
  role = aws_iam_role.lifecycle.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "AccountGuard"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
      {
        Sid      = "ControlState"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.lifecycle.arn
      },
      {
        Sid      = "ExactControlObjects"
        Effect   = "Allow"
        Action   = ["s3:GetBucketVersioning", "s3:ListBucket"]
        Resource = [aws_s3_bucket.control.arn, aws_s3_bucket.edge.arn]
      },
      {
        Sid      = "VersionedReleaseArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "arn:aws:s3:::${local.artifact_manifest_bucket}/${local.artifact_manifest_prefix}/*"
      },
      {
        Sid      = "TerraformStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:DeleteItem", "dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.terraform_locks.arn
      },
      {
        Sid    = "RunScopedObjects"
        Effect = "Allow"
        Action = ["s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.control.arn}/artifacts/${var.run_id}/*",
          "${aws_s3_bucket.control.arn}/evidence/${var.run_id}/*",
          "${aws_s3_bucket.control.arn}/runtime-state/${var.run_id}/*",
          "${aws_s3_bucket.control.arn}/security-logs/${var.run_id}/*",
          "${aws_s3_bucket.edge.arn}/*"
        ]
      },
      {
        Sid      = "NotificationsAndLifecycle"
        Effect   = "Allow"
        Action   = ["sns:Publish", "states:StartExecution"]
        Resource = [aws_sns_topic.lifecycle.arn, aws_sfn_state_machine.stop.arn]
      },
      {
        Sid      = "UpdateOwnNetworkPlacement"
        Effect   = "Allow"
        Action   = ["codebuild:UpdateProject"]
        Resource = "arn:aws:codebuild:${var.aws_region}:${var.authorized_account_id}:project/${local.name_prefix}-lifecycle"
      },
      {
        Sid      = "ObserveSafetySignals"
        Effect   = "Allow"
        Action   = ["budgets:ViewBudget", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "resourcegroupstaggingapi:GetResources"]
        Resource = "*"
      },
      {
        Sid      = "CloudFrontRuntimeOrigin"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateVpcOrigin", "cloudfront:DeleteVpcOrigin", "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:GetVpcOrigin", "cloudfront:ListVpcOrigins", "cloudfront:UpdateDistribution"]
        Resource = "*"
      },
      {
        Sid      = "PullExactLifecycleImage"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "PullLifecycleImageLayers"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:us-west-2:${var.authorized_account_id}:repository/*"
      },
      {
        Sid    = "TaggedRuntimeProvisioning"
        Effect = "Allow"
        Action = [
          "autoscaling:*", "cloudformation:*", "ec2:*", "ecr:*", "eks:*",
          "elasticloadbalancing:*",
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups", "logs:PutRetentionPolicy",
          "mq:*", "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:TagResource"
        ]
        Resource = "*"
      }
    ], local.runtime_iam_statements)
  })
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
          "test \"$PLANNING_COST_USD\" -le \"$COST_CEILING_USD\""
        ] }
        build = { commands = ["/usr/local/bin/osc-demo-lifecycle \"$ACTION\""] }
      }
    })
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.lifecycle_runner_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    dynamic "environment_variable" {
      for_each = merge(local.lifecycle_environment, { PLANNING_COST_USD = tostring(var.planning_cost_usd) })
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
        build = { commands = ["/usr/local/bin/osc-demo-lifecycle \"$ACTION\""] }
      }
    })
  }
  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.lifecycle_runner_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "SERVICE_ROLE"
    dynamic "environment_variable" {
      for_each = merge(local.lifecycle_environment, { PLANNING_COST_USD = tostring(var.planning_cost_usd) })
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
