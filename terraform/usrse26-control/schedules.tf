data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name_prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-exact-demo-workflows"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:StartExecution"]
      Resource = [aws_sfn_state_machine.start.arn, aws_sfn_state_machine.stop.arn, aws_sfn_state_machine.monitor.arn]
      }, {
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.scheduler_dlq.arn
    }]
  })
}

locals {
  one_time_schedules = {
    start       = { expression = "at(${var.start_at})", machine = aws_sfn_state_machine.start.arn, reason = "scheduled-start" }
    stop        = { expression = "at(${var.stop_at})", machine = aws_sfn_state_machine.stop.arn, reason = "scheduled-stop" }
    backup-stop = { expression = "at(${var.backup_stop_at})", machine = aws_sfn_state_machine.stop.arn, reason = "backup-stop" }
  }
}

resource "aws_scheduler_schedule" "one_time" {
  for_each                     = local.one_time_schedules
  name                         = "${local.name_prefix}-${each.key}"
  schedule_expression          = each.value.expression
  schedule_expression_timezone = "America/Los_Angeles"
  action_after_completion      = "DELETE"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = each.value.machine
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ runId = var.run_id, reason = each.value.reason, expectedAccount = var.authorized_account_id, expectedRegion = var.aws_region })
    dead_letter_config { arn = aws_sqs_queue.scheduler_dlq.arn }
    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}

resource "aws_scheduler_schedule" "monitor" {
  name                = "${local.name_prefix}-monitor"
  schedule_expression = "rate(5 minutes)"
  start_date          = "2026-10-20T15:00:00Z"
  end_date            = "2026-10-23T17:00:00Z"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sfn_state_machine.monitor.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ runId = var.run_id, reason = "active-monitor", expectedAccount = var.authorized_account_id, expectedRegion = var.aws_region })
    dead_letter_config { arn = aws_sqs_queue.scheduler_dlq.arn }
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 1
    }
  }
}
