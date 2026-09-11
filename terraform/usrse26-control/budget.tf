resource "aws_budgets_budget" "demo" {
  name         = "${local.name_prefix}-absolute-ceiling"
  budget_type  = "COST"
  limit_amount = "200"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:RunId$%s", var.run_id)]
  }

  dynamic "notification" {
    for_each = toset(["75", "125", "150", "200"])
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = tonumber(notification.value)
      threshold_type            = "ABSOLUTE_VALUE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.lifecycle.arn]
    }
  }
}
