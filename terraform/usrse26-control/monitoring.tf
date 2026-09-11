resource "aws_cloudwatch_metric_alarm" "codebuild_failed" {
  for_each = {
    lifecycle = aws_codebuild_project.lifecycle.name
    cleanup   = aws_codebuild_project.cleanup.name
  }
  alarm_name          = "${local.name_prefix}-${each.key}-build-failed"
  alarm_description   = "${each.key} CodeBuild failed; lifecycle teardown evidence requires review."
  namespace           = "AWS/CodeBuild"
  metric_name         = "FailedBuilds"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { ProjectName = each.value }
  alarm_actions       = [aws_sns_topic.lifecycle.arn]
}

resource "aws_cloudwatch_metric_alarm" "state_machine_failed" {
  for_each = {
    start   = aws_sfn_state_machine.start.arn
    stop    = aws_sfn_state_machine.stop.arn
    monitor = aws_sfn_state_machine.monitor.arn
  }
  alarm_name          = "${local.name_prefix}-${each.key}-failed"
  alarm_description   = "Demo ${each.key} state machine failed."
  namespace           = "AWS/States"
  metric_name         = "ExecutionsFailed"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { StateMachineArn = each.value }
  alarm_actions       = [aws_sns_topic.lifecycle.arn]
}

resource "aws_cloudwatch_metric_alarm" "scheduler_dlq" {
  alarm_name          = "${local.name_prefix}-scheduler-dlq"
  alarm_description   = "A scheduled lifecycle invocation exhausted retries."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = aws_sqs_queue.scheduler_dlq.name }
  alarm_actions       = [aws_sns_topic.lifecycle.arn]
}
