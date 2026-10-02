output "public_url" { value = "https://${var.public_hostname}" }
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.edge.id }
output "status_bucket" { value = aws_s3_bucket.edge.id }
output "control_bucket" { value = aws_s3_bucket.control.id }
output "lifecycle_table" { value = aws_dynamodb_table.lifecycle.name }
output "terraform_lock_table" { value = aws_dynamodb_table.terraform_locks.name }
output "start_state_machine_arn" { value = aws_sfn_state_machine.start.arn }
output "stop_state_machine_arn" { value = aws_sfn_state_machine.stop.arn }
output "monitor_state_machine_arn" { value = aws_sfn_state_machine.monitor.arn }
output "outside_vpc_cleanup_project" { value = aws_codebuild_project.cleanup.name }
output "notification_topic_arn" { value = aws_sns_topic.lifecycle.arn }
output "required_tags" { value = local.required_tags }
output "api_cache_policy_id" { value = aws_cloudfront_cache_policy.api.id }
output "api_origin_request_policy_id" { value = aws_cloudfront_origin_request_policy.api.id }
output "runtime_role_arns" { value = local.runtime_role_arn_map }
output "cost_control_mode" { value = var.cost_control_mode }
output "planning_estimate_usd" { value = var.planning_estimate_usd }
output "planning_estimate_ceiling_usd" { value = 200 }
output "maximum_runtime_hours" { value = 72 }
output "lifecycle_schedule" {
  value = {
    timezone    = "America/Los_Angeles"
    start       = var.start_at
    stop        = var.stop_at
    backup_stop = var.backup_stop_at
    hard_close  = local.lifecycle_environment.HARD_CLOSE_AT
  }
}
