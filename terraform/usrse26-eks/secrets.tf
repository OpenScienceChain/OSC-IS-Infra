resource "aws_secretsmanager_secret" "application" {
  name                    = "${local.name_prefix}/application"
  description             = "Disposable API and service authentication values"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "postgres" {
  name                    = "${local.name_prefix}/postgres"
  description             = "Disposable PostgreSQL credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  name                    = "${local.name_prefix}/rabbitmq"
  description             = "Disposable Amazon MQ credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "fabric_nsg" {
  name                    = "${local.name_prefix}/fabric/nsg"
  description             = "Disposable NSG Fabric service identity"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret" "fabric_citizen_science" {
  name                    = "${local.name_prefix}/fabric/citizen-science"
  description             = "Disposable Citizen Science Fabric service identity"
  recovery_window_in_days = 0
}

resource "terraform_data" "populate_initial_secrets" {
  triggers_replace = [
    aws_secretsmanager_secret.application.arn,
    aws_secretsmanager_secret.postgres.arn,
    aws_secretsmanager_secret.rabbitmq.arn,
  ]

  provisioner "local-exec" {
    command     = "${path.module}/scripts/populate_initial_secrets.py"
    interpreter = ["python"]
    environment = {
      AWS_PROFILE         = var.aws_profile
      AWS_REGION          = var.aws_region
      AUTHORIZED_ACCOUNT  = var.authorized_account_id
      APP_SECRET_ARN      = aws_secretsmanager_secret.application.arn
      POSTGRES_SECRET_ARN = aws_secretsmanager_secret.postgres.arn
      RABBITMQ_SECRET_ARN = aws_secretsmanager_secret.rabbitmq.arn
    }
  }
}
