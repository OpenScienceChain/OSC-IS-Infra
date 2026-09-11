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
    EXPECTED_ACCOUNT_ID      = var.authorized_account_id
    EXPECTED_REGION          = var.aws_region
    RUN_ID                   = var.run_id
    ADMIN_CIDR               = var.admin_cidr
    ARTIFACT_MANIFEST_S3_URI = var.artifact_manifest_s3_uri
    ARTIFACT_MANIFEST_SHA256 = var.artifact_manifest_sha256
    STATE_BUCKET             = aws_s3_bucket.control.id
    STATE_LOCK_TABLE         = aws_dynamodb_table.terraform_locks.name
    STATUS_BUCKET            = aws_s3_bucket.edge.id
    CLOUDFRONT_DISTRIBUTION  = aws_cloudfront_distribution.edge.id
    NOTIFICATION_TOPIC_ARN   = aws_sns_topic.lifecycle.arn
    HARD_CLOSE_AT            = "2026-10-23T15:00:00Z"
    MAX_RUNTIME_HOURS        = "72"
    COST_INFO_USD            = "75"
    COST_WARNING_USD         = "125"
    COST_TEARDOWN_USD        = "150"
    COST_CEILING_USD         = "200"
  }
}
