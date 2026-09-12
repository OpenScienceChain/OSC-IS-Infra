resource "aws_cloudwatch_log_group" "step_functions" {
  #checkov:skip=CKV_AWS_158: AWS-owned encryption avoids a KMS key whose deletion window would violate zero-residual teardown.
  #checkov:skip=CKV_AWS_338: Seven-day retention is proportionate for a disposable demo capped at 72 hours.
  name              = "/aws/vendedlogs/states/${local.name_prefix}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "step_functions_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions" {
  name               = "${local.name_prefix}-step-functions"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume.json
}

resource "aws_iam_role_policy" "step_functions" {
  #checkov:skip=CKV_AWS_290: Wildcards are limited to STS identity, CloudWatch Logs delivery, and X-Ray ingestion APIs that do not support resource scoping.
  #checkov:skip=CKV_AWS_355: The only Resource=* statements call non-resource-scoped identity, logging, and tracing APIs.
  name = "exact-demo-orchestration"
  role = aws_iam_role.step_functions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:BatchGetBuilds", "codebuild:StartBuild", "codebuild:StopBuild"]
        Resource = [aws_codebuild_project.lifecycle.arn, aws_codebuild_project.cleanup.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.lifecycle.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.lifecycle.arn
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutRule", "events:PutTargets", "events:DescribeRule"]
        Resource = "arn:aws:events:us-west-2:${var.authorized_account_id}:rule/StepFunctionsGetEventForCodeBuildStartBuildRule"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery", "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutLogEvents", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "start" {
  #checkov:skip=CKV_AWS_285: Execution-data logging is deliberately disabled so request payloads cannot enter logs; state transitions are logged at ALL level.
  name     = "${local.name_prefix}-start"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  logging_configuration {
    include_execution_data = false
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
  }

  tracing_configuration { enabled = true }

  definition = jsonencode({
    Comment = "Guarded, idempotent start with two retries and canary-open gate"
    StartAt = "VerifyAccount"
    States = {
      VerifyAccount = {
        Type       = "Task"
        Resource   = "arn:aws:states:::aws-sdk:sts:getCallerIdentity"
        Parameters = {}
        ResultPath = "$.identity"
        Next       = "AuthorizedAccount"
      }
      AuthorizedAccount = {
        Type    = "Choice"
        Choices = [{ Variable = "$.identity.Account", StringEquals = var.authorized_account_id, Next = "ReadRun" }]
        Default = "Unauthorized"
      }
      Unauthorized = { Type = "Fail", Error = "UnauthorizedAccount", Cause = "Expected AWS account 269624229733" }
      ReadRun = {
        Type       = "Task"
        Resource   = "arn:aws:states:::dynamodb:getItem"
        Parameters = { TableName = aws_dynamodb_table.lifecycle.name, Key = { runId = { "S.$" = "$.runId" } } }
        ResultPath = "$.existing"
        Next       = "RunExists"
      }
      RunExists = {
        Type    = "Choice"
        Choices = [{ Variable = "$.existing.Item.runId.S", IsPresent = true, Next = "AlreadyStarted" }]
        Default = "ReserveRun"
      }
      AlreadyStarted = { Type = "Succeed" }
      ReserveRun = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.lifecycle.name
          Item = {
            runId          = { "S.$" = "$.runId" }
            status         = { S = "PREPARING" }
            hardCloseAt    = { S = local.lifecycle_environment.HARD_CLOSE_AT }
            expiresAtEpoch = { N = "1795359600" }
          }
          ConditionExpression = "attribute_not_exists(runId)"
        }
        Next = "ProvisionAndDeploy"
      }
      ProvisionAndDeploy = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.lifecycle.name
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Value = "START", Type = "PLAINTEXT" },
            { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }
          ]
        }
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, BackoffRate = 2, MaxAttempts = 3 }]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.failure", Next = "FailedStartCleanup" }]
        ResultPath = "$.startBuild"
        Next       = "PublicCanary"
      }
      PublicCanary = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.lifecycle.name
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Value = "CANARY", Type = "PLAINTEXT" },
            { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }
          ]
        }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.failure", Next = "FailedStartCleanup" }]
        ResultPath = "$.canaryBuild"
        Next       = "MarkOpen"
      }
      MarkOpen = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.lifecycle.name
          Key                       = { runId = { "S.$" = "$.runId" } }
          UpdateExpression          = "SET #s = :open"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = { ":open" = { S = "OPEN" } }
        }
        End = true
      }
      FailedStartCleanup = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.lifecycle.name
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Value = "FAILED_START_CLEANUP", Type = "PLAINTEXT" },
            { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }
          ]
        }
        Retry = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, BackoffRate = 2, MaxAttempts = 3 }]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.cleanupFailure", Next = "FailedStartDestroyRuntime" }]
        Next  = "WaitForFailedStartNetworkRelease"
      }
      WaitForFailedStartNetworkRelease = { Type = "Wait", Seconds = 120, Next = "FailedStartDestroyRuntime" }
      FailedStartDestroyRuntime = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.cleanup.name
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Value = "DESTROY_RUNTIME", Type = "PLAINTEXT" },
            { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }
          ]
        }
        Retry = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 120, BackoffRate = 2, MaxAttempts = 3 }]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.destroyFailure", Next = "FailedStartSweep" }]
        Next  = "FailedStartSweep"
      }
      FailedStartSweep = {
        Type     = "Task"
        Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = {
          ProjectName = aws_codebuild_project.cleanup.name
          EnvironmentVariablesOverride = [
            { Name = "ACTION", Value = "SWEEP", Type = "PLAINTEXT" },
            { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }
          ]
        }
        Retry = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, BackoffRate = 2, MaxAttempts = 3 }]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.sweepFailure", Next = "NotifyFailure" }]
        Next  = "NotifyFailure"
      }
      NotifyFailure = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.lifecycle.arn, Subject = "OSC-IS demo start failed", Message = "The static fallback remains available; incomplete tagged runtime cleanup was requested." }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notificationFailure", Next = "StartFailed" }]
        Next       = "StartFailed"
      }
      StartFailed = { Type = "Fail", Error = "StartOrCanaryFailed" }
    }
  })
}

resource "aws_sfn_state_machine" "stop" {
  #checkov:skip=CKV_AWS_285: Execution-data logging is deliberately disabled so request payloads cannot enter logs; state transitions are logged at ALL level.
  name     = "${local.name_prefix}-stop"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  logging_configuration {
    include_execution_data = false
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
  }

  tracing_configuration { enabled = true }

  definition = jsonencode({
    Comment = "Read-only, drain, export, destroy, sweep, and verify"
    StartAt = "VerifyAccount"
    States = {
      VerifyAccount = { Type = "Task", Resource = "arn:aws:states:::aws-sdk:sts:getCallerIdentity", Parameters = {}, ResultPath = "$.identity", Next = "AuthorizedAccount" }
      AuthorizedAccount = {
        Type    = "Choice"
        Choices = [{ Variable = "$.identity.Account", StringEquals = var.authorized_account_id, Next = "BackupActivation" }]
        Default = "Unauthorized"
      }
      Unauthorized = { Type = "Fail", Error = "UnauthorizedAccount", Cause = "Expected AWS account 269624229733" }
      BackupActivation = {
        Type    = "Choice"
        Choices = [{ Variable = "$.reason", StringEquals = "backup-stop", Next = "NotifyBackupActivation" }]
        Default = "ReadRun"
      }
      NotifyBackupActivation = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.lifecycle.arn, Subject = "OSC-IS demo backup stop activated", Message = "The independent backup stop is checking teardown after the primary stop window." }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notificationFailure", Next = "ReadRun" }]
        Next       = "ReadRun"
      }
      ReadRun = {
        Type       = "Task"
        Resource   = "arn:aws:states:::dynamodb:getItem"
        Parameters = { TableName = aws_dynamodb_table.lifecycle.name, Key = { runId = { "S.$" = "$.runId" } }, ConsistentRead = true }
        ResultPath = "$.existing"
        Next       = "AlreadyClosed"
      }
      AlreadyClosed = {
        Type = "Choice"
        Choices = [{
          And = [
            { Variable = "$.existing.Item.status.S", IsPresent = true },
            { Variable = "$.existing.Item.status.S", StringEquals = "CLOSED" }
          ]
          Next = "StopComplete"
        }]
        Default = "ReadOnly"
      }
      StopComplete = { Type = "Succeed" }
      ReadOnly = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.lifecycle.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "READ_ONLY", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.readOnlyFailure", Next = "NotifyReadOnlyFailure" }]
        Next       = "Drain"
      }
      NotifyReadOnlyFailure = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.lifecycle.arn, Subject = "OSC-IS demo read-only transition failed", Message = "Cleanup will continue outside the runtime VPC." }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notificationFailure", Next = "Drain" }]
        Next       = "Drain"
      }
      Drain = { Type = "Wait", Seconds = 900, Next = "Export" }
      Export = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.lifecycle.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "EXPORT", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.exportFailure", Next = "NotifyExportFailure" }]
        Next       = "Destroy"
      }
      NotifyExportFailure = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.lifecycle.arn, Subject = "OSC-IS demo evidence export failed", Message = "Runtime destruction will continue; evidence is incomplete." }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notificationFailure", Next = "Destroy" }]
        Next       = "Destroy"
      }
      Destroy = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.lifecycle.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "DESTROY", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, BackoffRate = 2, MaxAttempts = 3 }]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.workloadDestroyFailure", Next = "DestroyRuntime" }]
        Next       = "WaitForRunnerNetworkRelease"
      }
      WaitForRunnerNetworkRelease = { Type = "Wait", Seconds = 120, Next = "DestroyRuntime" }
      DestroyRuntime = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.cleanup.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "DESTROY_RUNTIME", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 120, BackoffRate = 2, MaxAttempts = 3 }]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.runtimeDestroyFailure", Next = "Sweep" }]
        Next       = "Sweep"
      }
      Sweep = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.cleanup.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "SWEEP", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        Retry      = [{ ErrorEquals = ["States.TaskFailed"], IntervalSeconds = 60, BackoffRate = 2, MaxAttempts = 3 }]
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.sweepFailure", Next = "NotifyIncompleteSweep" }]
        Next       = "MarkClosed"
      }
      NotifyIncompleteSweep = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.lifecycle.arn, Subject = "OSC-IS demo teardown incomplete", Message = "The outside-VPC sweep found residual runtime resources. Immediate operator action is required." }
        Catch      = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.notificationFailure", Next = "StopFailed" }]
        Next       = "StopFailed"
      }
      StopFailed = { Type = "Fail", Error = "RuntimeTeardownIncomplete", Cause = "Outside-VPC destruction or sweep did not verify an empty inventory" }
      MarkClosed = {
        Type = "Task", Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.lifecycle.name
          Key                       = { runId = { "S.$" = "$.runId" } }
          UpdateExpression          = "SET #s = :closed"
          ExpressionAttributeNames  = { "#s" = "status" }
          ExpressionAttributeValues = { ":closed" = { S = "CLOSED" } }
        }
        End = true
      }
    }
  })
}

resource "aws_sfn_state_machine" "monitor" {
  #checkov:skip=CKV_AWS_285: Execution-data logging is deliberately disabled so request payloads cannot enter logs; state transitions are logged at ALL level.
  name     = "${local.name_prefix}-monitor"
  role_arn = aws_iam_role.step_functions.arn
  type     = "STANDARD"

  logging_configuration {
    include_execution_data = false
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
  }

  tracing_configuration { enabled = true }

  definition = jsonencode({
    StartAt = "VerifyAccount"
    States = {
      VerifyAccount     = { Type = "Task", Resource = "arn:aws:states:::aws-sdk:sts:getCallerIdentity", Parameters = {}, ResultPath = "$.identity", Next = "AuthorizedAccount" }
      AuthorizedAccount = { Type = "Choice", Choices = [{ Variable = "$.identity.Account", StringEquals = var.authorized_account_id, Next = "Monitor" }], Default = "Unauthorized" }
      Unauthorized      = { Type = "Fail", Error = "UnauthorizedAccount" }
      Monitor = {
        Type       = "Task", Resource = "arn:aws:states:::codebuild:startBuild.sync"
        Parameters = { ProjectName = aws_codebuild_project.lifecycle.name, EnvironmentVariablesOverride = [{ Name = "ACTION", Value = "MONITOR", Type = "PLAINTEXT" }, { Name = "RUN_ID", "Value.$" = "$.runId", Type = "PLAINTEXT" }] }
        End        = true
      }
    }
  })
}
