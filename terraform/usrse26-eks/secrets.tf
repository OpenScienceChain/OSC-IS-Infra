resource "aws_secretsmanager_secret" "api_auth" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/api/auth"
  description             = "Disposable API authentication and bootstrap values"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "listener_auth" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/submission-listener/auth"
  description             = "Disposable submission-listener callback authentication"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "demo_auth" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/demo/auth"
  description             = "Disposable internal demo-control authentication"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "ledger_nsg_auth" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/ledger/nsg/auth"
  description             = "Disposable NSG Ledger Gateway authentication"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "ledger_citizen_science_auth" {
  #checkov:skip=CKV_AWS_149: AWS-owned encryption avoids a KMS key whose deletion window would outlive exact teardown.
  #checkov:skip=CKV2_AWS_57: The generated credential is destroyed within 72 hours, before a rotation interval would elapse.
  name                    = "${local.name_prefix}/ledger/citizen-science/auth"
  description             = "Disposable Citizen Science Ledger Gateway authentication"
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
    aws_secretsmanager_secret.api_auth.arn,
    aws_secretsmanager_secret.listener_auth.arn,
    aws_secretsmanager_secret.demo_auth.arn,
    aws_secretsmanager_secret.ledger_nsg_auth.arn,
    aws_secretsmanager_secret.ledger_citizen_science_auth.arn,
    aws_secretsmanager_secret.postgres.arn,
    aws_secretsmanager_secret.rabbitmq.arn,
  ]

  provisioner "local-exec" {
    command     = "${path.module}/scripts/populate_initial_secrets.py"
    interpreter = ["python"]
    environment = {
      AWS_PROFILE                = var.aws_profile
      AWS_REGION                 = var.aws_region
      AUTHORIZED_ACCOUNT         = var.authorized_account_id
      API_AUTH_SECRET_ARN        = aws_secretsmanager_secret.api_auth.arn
      LISTENER_AUTH_SECRET_ARN   = aws_secretsmanager_secret.listener_auth.arn
      DEMO_AUTH_SECRET_ARN       = aws_secretsmanager_secret.demo_auth.arn
      LEDGER_NSG_AUTH_SECRET_ARN = aws_secretsmanager_secret.ledger_nsg_auth.arn
      LEDGER_CITIZEN_SECRET_ARN  = aws_secretsmanager_secret.ledger_citizen_science_auth.arn
      POSTGRES_SECRET_ARN        = aws_secretsmanager_secret.postgres.arn
      RABBITMQ_SECRET_ARN        = aws_secretsmanager_secret.rabbitmq.arn
    }
  }
}
