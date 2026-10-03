resource "aws_cloudformation_stack" "rabbitmq" {
  #checkov:skip=CKV_AWS_124: Lifecycle alarms and the backup-stop workflow are the bounded experiment notification path; no stack-level SNS fanout is retained.
  name               = "${local.name_prefix}-rabbitmq"
  template_body      = file("${path.module}/templates/rabbitmq.json")
  timeout_in_minutes = 30
  on_failure         = "DELETE"

  parameters = {
    BrokerName       = "${local.name_prefix}-rabbitmq"
    EngineVersion    = var.rabbitmq_engine_version
    HostInstanceType = var.rabbitmq_instance_type
    SubnetIds        = join(",", aws_subnet.private[*].id)
    SecurityGroupId  = aws_security_group.rabbitmq.id
    SecretName       = "${local.name_prefix}/rabbitmq"
    ProjectTag       = local.required_tags.Project
    PurposeTag       = local.required_tags.Purpose
    EnvironmentTag   = local.required_tags.Environment
    ManagedByTag     = local.required_tags.ManagedBy
    OwnerTag         = local.required_tags.Owner
    RunIdTag         = local.required_tags.RunId
    ExpiresAtTag     = local.required_tags.ExpiresAt
  }

  depends_on = [terraform_data.populate_initial_secrets]
}
