provider "aws" {
  region = var.region
}

data "aws_ecs_cluster" "this" {
  cluster_name = var.ecs_cluster_name
}

locals {
  runtime_mode = lower(var.runtime_mode)

  desired_counts = {
    for name, cfg in var.services :
    name => local.runtime_mode == "down" ? 0 : cfg.desired_count
  }

  ec2_runtime_state = local.runtime_mode == "down" ? "stopped" : "running"

  managed_ec2_instances = var.manage_ec2_runtime_state ? {
    for id in var.ec2_instance_ids : id => id
  } : {}
}

locals {
  # Infra-derived overrides injected into every task-def template.
  # Values come from live Terraform resources so they are always correct on
  # a fresh deploy — no hardcoding, no two-pass apply.
  #
  # Security notes:
  #   - db_host uses a private Route53 CNAME (osc-infra.local) — never public.
  #   - db_ssl_servername uses the actual RDS endpoint for TLS CN verification.
  #   - DB credentials are stored in Secrets Manager (stable name, stable ARN).
  #   - rabbitmq_host uses a private Route53 CNAME — NLB is internal-only.
  #
  # Hibernation note: when infra_mode=hibernated the RDS/NLB/Route53 resources
  # are destroyed; try() falls back to "". Task defs keep prior values via
  # ignore_changes=all and services run at desired_count=0, so no impact.
  base_infra_overrides = {
    db_host                = try(aws_route53_record.rds_private[0].fqdn, "")
    db_ssl_servername      = try(aws_db_instance.this[0].address, "")
    db_password_secret_arn = try("${aws_secretsmanager_secret.db_master[0].arn}:password::", "")
    db_user_secret_arn     = try("${aws_secretsmanager_secret.db_master[0].arn}:username::", "")
    rabbitmq_host = local.amazon_mq_active ? trimprefix(
      split(":", aws_mq_broker.rabbitmq[0].instances[0].endpoints[0])[1],
      "//"
    ) : try(aws_route53_record.rabbitmq_private[0].fqdn, "")
  }

  amazon_mq_overrides = local.amazon_mq_active ? {
    rabbitmq_port            = "5671"
    rabbitmq_user_secret_arn = "${aws_secretsmanager_secret.rabbitmq[0].arn}:username::"
    rabbitmq_pass_secret_arn = "${aws_secretsmanager_secret.rabbitmq[0].arn}:password::"
  } : {}

  infra_overrides = merge(local.base_infra_overrides, local.amazon_mq_overrides)

  service_defs = {
    for name, cfg in var.services :
    name => jsondecode(
      (
        try(
          templatefile(cfg.task_def_template_path, merge(cfg.task_def_vars, local.infra_overrides)),
          ""
        ) != ""
      ) ? templatefile(cfg.task_def_template_path, merge(cfg.task_def_vars, local.infra_overrides)) : file(cfg.task_def_path)
    )
  }
}

resource "aws_cloudwatch_log_group" "ecs" {
  for_each          = var.services
  name              = "/ecs/${each.key}"
  retention_in_days = var.log_retention_in_days

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecs_task_definition" "this" {
  for_each = local.service_defs

  family                   = each.value.family
  network_mode             = each.value.networkMode
  requires_compatibilities = each.value.requiresCompatibilities
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = each.value.executionRoleArn
  task_role_arn            = each.value.taskRoleArn
  container_definitions    = jsonencode(each.value.containerDefinitions)

  lifecycle {
    prevent_destroy = true
    # Task definition config (image, env vars, cpu, memory) is managed by CI/CD.
    # Terraform imports task defs to track their ARN in state but never replaces them.
    # Use the deployment pipeline to push new task definition revisions.
    ignore_changes = all
  }
}

resource "aws_ecs_service" "this" {
  for_each = var.services

  name                   = each.key
  cluster                = data.aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this[each.key].arn
  desired_count          = local.desired_counts[each.key]
  launch_type            = "FARGATE"
  enable_execute_command = each.value.enable_exec

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = var.assign_public_ip
  }

  dynamic "service_registries" {
    for_each = try(each.value.cloud_map_service_arn, null) != null ? [1] : []
    content {
      registry_arn = each.value.cloud_map_service_arn
    }
  }

  dynamic "load_balancer" {
    for_each = try(each.value.alb_container_name, null) != null && local.infra_active && var.alb != null ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.alb[0].arn
      container_name   = each.value.alb_container_name
      container_port   = each.value.alb_container_port
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [task_definition]
  }
}

resource "aws_ec2_instance_state" "runtime" {
  for_each    = local.managed_ec2_instances
  instance_id = each.value
  state       = local.ec2_runtime_state
}
