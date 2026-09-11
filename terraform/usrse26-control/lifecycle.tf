resource "aws_s3_bucket" "control" {
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
  bucket = aws_s3_bucket.control.id
  rule {
    id     = "expire-sanitized-evidence"
    status = "Enabled"
    filter { prefix = "evidence/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
  rule {
    id     = "expire-security-logs"
    status = "Enabled"
    filter { prefix = "security-logs/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 1 }
  }
  rule {
    id     = "expire-runtime-state"
    status = "Enabled"
    filter { prefix = "runtime-state/" }
    expiration { days = 30 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

resource "aws_dynamodb_table" "lifecycle" {
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
  name         = "${local.name_prefix}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  server_side_encryption { enabled = true }
}

resource "aws_sns_topic" "lifecycle" {
  name = "${local.name_prefix}-notifications"
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
  name              = "/aws/codebuild/${local.name_prefix}-lifecycle"
  retention_in_days = 7
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

resource "aws_iam_role" "lifecycle" {
  name                 = "${local.name_prefix}-lifecycle"
  assume_role_policy   = data.aws_iam_policy_document.codebuild_assume.json
  permissions_boundary = var.lifecycle_permissions_boundary_arn
}

resource "aws_iam_role_policy" "lifecycle" {
  name = "bounded-demo-lifecycle"
  role = aws_iam_role.lifecycle.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
        Resource = aws_s3_bucket.control.arn
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
          "elasticloadbalancing:*", "iam:CreatePolicy", "iam:CreateRole", "iam:DeletePolicy",
          "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:GetPolicy", "iam:GetRole",
          "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
          "iam:ListPolicyVersions", "iam:ListRolePolicies", "iam:PassRole", "iam:PutRolePolicy",
          "iam:TagPolicy", "iam:TagRole", "iam:UntagPolicy", "iam:UntagRole",
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups", "logs:PutRetentionPolicy",
          "mq:*", "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:TagResource"
        ]
        Resource = "*"
      }
    ]
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
