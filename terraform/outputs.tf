output "task_definition_arns" {
  value = {
    for name, td in aws_ecs_task_definition.this :
    name => td.arn
  }
}

output "service_arns" {
  value = {
    for name, svc in aws_ecs_service.this :
    name => svc.arn
  }
}

output "ecs_desired_counts" {
  value = {
    for name, svc in aws_ecs_service.this :
    name => svc.desired_count
  }
}

output "managed_ec2_instance_state" {
  value = {
    for id, state in aws_ec2_instance_state.runtime :
    id => state.state
  }
}

output "alb_dns_name" {
  value = try(aws_lb.alb[0].dns_name, null)
}

output "nlb_dns_name" {
  value = try(aws_lb.nlb[0].dns_name, null)
}

output "nat_gateway_id" {
  value = try(aws_nat_gateway.this[0].id, null)
}

output "rds_instance_identifier" {
  value = try(aws_db_instance.this[0].identifier, null)
}

output "rds_endpoint" {
  value = try(aws_db_instance.this[0].address, null)
}

output "rds_master_secret_arn" {
  description = "ARN of the Terraform-managed Secrets Manager secret for DB master credentials."
  value       = try(aws_secretsmanager_secret.db_master[0].arn, null)
}

output "db_private_fqdn" {
  description = "Private DNS name for the RDS instance (db.osc-infra.local)."
  value       = try(aws_route53_record.rds_private[0].fqdn, null)
}

output "rabbitmq_private_fqdn" {
  description = "Private DNS name for the RabbitMQ NLB (rabbitmq.osc-infra.local)."
  value       = try(aws_route53_record.rabbitmq_private[0].fqdn, null)
}

output "rabbitmq_backend" {
  description = "Selected RabbitMQ implementation."
  value       = lower(var.messaging_backend)
}

output "amazon_mq_amqps_endpoint" {
  description = "Private AMQPS endpoint when the Amazon MQ profile is active."
  value       = try(aws_mq_broker.rabbitmq[0].instances[0].endpoints[0], null)
  sensitive   = true
}

output "rabbitmq_credentials_secret_arn" {
  description = "Secrets Manager ARN containing username and password for Amazon MQ."
  value       = try(aws_secretsmanager_secret.rabbitmq[0].arn, null)
}
