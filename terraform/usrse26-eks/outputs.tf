output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "region" {
  value = var.aws_region
}

output "run_id" {
  value = var.run_id
}

output "expires_at" {
  value = var.expires_at
}

output "cluster_name" {
  value = aws_eks_cluster.experiment.name
}

output "cluster_version" {
  value = aws_eks_cluster.experiment.version
}

output "vpc_id" {
  value = aws_vpc.experiment.id
}

output "vpc_cidr" {
  value = aws_vpc.experiment.cidr_block
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "ecr_repositories" {
  value = { for name, repository in aws_ecr_repository.experiment : name => repository.repository_url }
}

output "secret_arns" {
  value = {
    application    = aws_secretsmanager_secret.application.arn
    postgres       = aws_secretsmanager_secret.postgres.arn
    rabbitmq       = aws_secretsmanager_secret.rabbitmq.arn
    fabric_nsg     = aws_secretsmanager_secret.fabric_nsg.arn
    fabric_citizen = aws_secretsmanager_secret.fabric_citizen_science.arn
  }
}

output "rabbitmq_amqps_endpoint" {
  value     = aws_cloudformation_stack.rabbitmq.outputs["AmqpsEndpoint"]
  sensitive = true
}

output "required_tags" {
  value = local.required_tags
}
