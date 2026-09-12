locals {
  name_prefix              = "osc-usrse26-${var.run_id}"
  artifact_manifest_parts  = split("/", trimprefix(var.artifact_manifest_s3_uri, "s3://"))
  artifact_manifest_bucket = local.artifact_manifest_parts[0]
  artifact_manifest_key    = join("/", slice(local.artifact_manifest_parts, 1, length(local.artifact_manifest_parts)))
  artifact_manifest_prefix = dirname(local.artifact_manifest_key)

  required_tags = {
    Project     = "OSC-IS"
    Purpose     = "USRSE26-Interactive-Demo"
    Environment = "ephemeral"
    ManagedBy   = "Terraform"
    Owner       = "ofgarzon"
    RunId       = var.run_id
    ExpiresAt   = "2026-11-22T15:00:00Z"
  }

  lifecycle_environment = {
    EXPECTED_ACCOUNT_ID           = var.authorized_account_id
    EXPECTED_REGION               = var.aws_region
    RUN_ID                        = var.run_id
    ADMIN_CIDR                    = var.admin_cidr
    ARTIFACT_MANIFEST_S3_URI      = var.artifact_manifest_s3_uri
    ARTIFACT_MANIFEST_SHA256      = var.artifact_manifest_sha256
    STATE_BUCKET                  = aws_s3_bucket.control.id
    STATE_LOCK_TABLE              = aws_dynamodb_table.terraform_locks.name
    STATUS_BUCKET                 = aws_s3_bucket.edge.id
    CLOUDFRONT_DISTRIBUTION       = aws_cloudfront_distribution.edge.id
    NOTIFICATION_TOPIC_ARN        = aws_sns_topic.lifecycle.arn
    LIFECYCLE_TABLE               = aws_dynamodb_table.lifecycle.name
    LIFECYCLE_CODEBUILD_PROJECT   = "${local.name_prefix}-lifecycle"
    STOP_STATE_MACHINE_ARN        = "arn:aws:states:${var.aws_region}:${var.authorized_account_id}:stateMachine:${local.name_prefix}-stop"
    PUBLIC_URL                    = "https://${var.public_hostname}"
    API_CACHE_POLICY_ID           = aws_cloudfront_cache_policy.api.id
    API_ORIGIN_POLICY_ID          = aws_cloudfront_origin_request_policy.api.id
    WEB_ACL_NAME                  = aws_wafv2_web_acl.edge.name
    RUNTIME_ROLE_ARNS_JSON        = jsonencode(local.runtime_role_arn_map)
    HARD_CLOSE_AT                 = "2026-10-23T15:00:00Z"
    MAX_RUNTIME_HOURS             = "72"
    COST_CONTROL_MODE             = var.cost_control_mode
    PLANNING_ESTIMATE_CEILING_USD = "200"
  }
}
