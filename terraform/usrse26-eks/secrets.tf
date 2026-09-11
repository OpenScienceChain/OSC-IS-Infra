resource "aws_secretsmanager_secret" "application" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/api"
  description             = "Disposable API-only authentication and demo-control values"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "listener" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/listener"
  description             = "Disposable API-to-listener credential"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "ledger_nsg_token" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/ledger-token/nsg"
  description             = "Disposable NSG ledger-gateway bearer token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "ledger_citizen_science_token" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/ledger-token/citizen-science"
  description             = "Disposable Citizen Science ledger-gateway bearer token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "postgres" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/postgres"
  description             = "Disposable PostgreSQL credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/rabbitmq"
  description             = "Disposable Amazon MQ credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "fabric_nsg" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated identity is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/fabric/nsg"
  description             = "Disposable NSG Fabric service identity"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "fabric_citizen_science" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated identity is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/fabric/citizen-science"
  description             = "Disposable Citizen Science Fabric service identity"
  recovery_window_in_days = 0
}

resource "terraform_data" "populate_initial_secrets" {
  triggers_replace = [
    aws_secretsmanager_secret.application.arn,
    aws_secretsmanager_secret.listener.arn,
    aws_secretsmanager_secret.ledger_nsg_token.arn,
    aws_secretsmanager_secret.ledger_citizen_science_token.arn,
    aws_secretsmanager_secret.postgres.arn,
    aws_secretsmanager_secret.rabbitmq.arn,
  ]

  provisioner "local-exec" {
    command     = "${path.module}/scripts/populate_initial_secrets.py"
    interpreter = ["python"]
    environment = {
      AWS_PROFILE              = var.aws_profile
      AWS_REGION               = var.aws_region
      AUTHORIZED_ACCOUNT       = var.authorized_account_id
      APP_SECRET_ARN           = aws_secretsmanager_secret.application.arn
      LISTENER_SECRET_ARN      = aws_secretsmanager_secret.listener.arn
      NSG_TOKEN_SECRET_ARN     = aws_secretsmanager_secret.ledger_nsg_token.arn
      CITIZEN_TOKEN_SECRET_ARN = aws_secretsmanager_secret.ledger_citizen_science_token.arn
      POSTGRES_SECRET_ARN      = aws_secretsmanager_secret.postgres.arn
      RABBITMQ_SECRET_ARN      = aws_secretsmanager_secret.rabbitmq.arn
    }
  }
}
