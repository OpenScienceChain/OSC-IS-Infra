locals {
  infra_mode_normalized = lower(var.infra_mode)
  infra_active          = var.manage_hybrid_infra && local.infra_mode_normalized == "active"
  infra_hibernated      = var.manage_hybrid_infra && local.infra_mode_normalized == "hibernated"

  nat_requires_eip     = local.infra_active && var.nat != null && try(var.nat.allocation_id, null) == null && try(var.nat.create_eip, true)
  ec2_messaging_active = local.infra_active && lower(var.messaging_backend) == "ec2"
  amazon_mq_active     = local.infra_active && lower(var.messaging_backend) == "amazon_mq" && var.amazon_mq != null
}

check "amazon_mq_configuration" {
  assert {
    condition     = lower(var.messaging_backend) != "amazon_mq" || var.amazon_mq != null
    error_message = "Set amazon_mq when messaging_backend=amazon_mq."
  }
}

check "confirm_hibernation_destroy" {
  assert {
    condition     = !local.infra_hibernated || var.allow_destroy
    error_message = "infra_mode=hibernated is destructive. Set allow_destroy=true to proceed."
  }
}

check "rds_final_snapshot_required" {
  assert {
    condition     = !local.infra_hibernated || var.rds == null || try(var.rds.skip_final_snapshot, true) || try(var.rds.final_snapshot_identifier, null) != null
    error_message = "When hibernating RDS with skip_final_snapshot=false, set rds.final_snapshot_identifier to avoid naming conflicts."
  }
}

resource "aws_lb_target_group" "alb" {
  count       = local.infra_active && var.alb != null ? 1 : 0
  name        = var.alb.target_group.name
  port        = var.alb.target_group.port
  protocol    = var.alb.target_group.protocol
  target_type = try(var.alb.target_group.target_type, "ip")
  vpc_id      = var.vpc_id

  health_check {
    enabled = true
    path    = try(var.alb.target_group.health_check_path, "/")
  }
}

resource "aws_lb" "alb" {
  count                      = local.infra_active && var.alb != null ? 1 : 0
  name                       = var.alb.name
  internal                   = var.alb.internal
  load_balancer_type         = "application"
  security_groups            = var.alb.security_group_ids
  subnets                    = var.alb.subnet_ids
  idle_timeout               = try(var.alb.idle_timeout, 60)
  enable_deletion_protection = try(var.alb.enable_deletion_protection, false)
  tags                       = try(var.alb.tags, {})
}

resource "aws_lb_listener" "alb" {
  count             = local.infra_active && var.alb != null ? 1 : 0
  load_balancer_arn = aws_lb.alb[0].arn
  port              = try(var.alb.listener_port, 443)
  protocol          = try(var.alb.listener_protocol, "HTTPS")
  certificate_arn   = try(var.alb.certificate_arn, null)

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb[0].arn
  }
}

resource "aws_route53_record" "alb_alias" {
  count   = local.infra_active && var.alb != null && try(var.alb.route53_record_name, null) != null && try(var.alb.route53_zone_id, null) != null ? 1 : 0
  zone_id = var.alb.route53_zone_id
  name    = var.alb.route53_record_name
  type    = "A"

  alias {
    name                   = aws_lb.alb[0].dns_name
    zone_id                = aws_lb.alb[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_target_group" "nlb" {
  count       = local.ec2_messaging_active && var.nlb != null ? 1 : 0
  name        = var.nlb.target_group.name
  port        = var.nlb.target_group.port
  protocol    = var.nlb.target_group.protocol
  target_type = try(var.nlb.target_group.target_type, "ip")
  vpc_id      = var.vpc_id
}

resource "aws_lb" "nlb" {
  count              = local.ec2_messaging_active && var.nlb != null ? 1 : 0
  name               = var.nlb.name
  internal           = var.nlb.internal
  load_balancer_type = "network"
  subnets            = var.nlb.subnet_ids
  # Required: EC2 target lives in one AZ; tasks may run in any AZ.
  # Without cross-zone LB, tasks in the other AZ get connection refused/timeout.
  enable_cross_zone_load_balancing = true
  tags                             = try(var.nlb.tags, {})
}

resource "aws_lb_listener" "nlb" {
  count             = local.ec2_messaging_active && var.nlb != null ? 1 : 0
  load_balancer_arn = aws_lb.nlb[0].arn
  port              = try(var.nlb.listener_port, 5672)
  protocol          = try(var.nlb.listener_protocol, "TCP")

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb[0].arn
  }
}

resource "aws_route53_record" "nlb_alias" {
  count   = local.ec2_messaging_active && var.nlb != null && try(var.nlb.route53_record_name, null) != null && try(var.nlb.route53_zone_id, null) != null ? 1 : 0
  zone_id = var.nlb.route53_zone_id
  name    = var.nlb.route53_record_name
  type    = "A"

  alias {
    name                   = aws_lb.nlb[0].dns_name
    zone_id                = aws_lb.nlb[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_eip" "nat" {
  count = local.nat_requires_eip ? 1 : 0
  tags  = try(var.nat.eip_tags, {})
}

resource "aws_nat_gateway" "this" {
  count         = local.infra_active && var.nat != null ? 1 : 0
  subnet_id     = var.nat.subnet_id
  allocation_id = try(var.nat.allocation_id, null) != null ? var.nat.allocation_id : aws_eip.nat[0].id
  tags          = try(var.nat.nat_tags, {})
}

resource "aws_route" "private_default_ipv4" {
  for_each = local.infra_active && var.nat != null ? toset(var.nat.private_route_table_ids) : toset([])

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# ---------------------------------------------------------------------------
# Stable DB master credentials
# NOT conditional on infra_active so the secret (and its ARN) persists through
# hibernation cycles. The ARN in ECS task definitions stays valid without any
# task-def update after a bring-up.
# ---------------------------------------------------------------------------
resource "random_password" "db_master" {
  count  = var.rds != null ? 1 : 0
  length = 32
  # Exclude chars that break PostgreSQL connection strings or shell quoting
  special          = true
  override_special = "!#%&*()-_=+[]{};<>?"
  keepers = {
    # Regenerate only if the DB identifier changes
    rds_identifier = var.rds.identifier
  }
}

resource "aws_secretsmanager_secret" "db_master" {
  count = var.rds != null ? 1 : 0
  name  = var.rds.master_secret_name
  # Allow immediate deletion so make down + make up works without waiting
  # for the default 7-day recovery window
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_master" {
  count     = var.rds != null ? 1 : 0
  secret_id = aws_secretsmanager_secret.db_master[0].id
  secret_string = jsonencode({
    username = var.rds.username
    password = random_password.db_master[0].result
  })
  lifecycle {
    # Don't overwrite the secret if it was rotated outside Terraform
    ignore_changes = [secret_string]
  }
}

resource "aws_db_subnet_group" "this" {
  count      = local.infra_active && var.rds != null && try(var.rds.db_subnet_group_name, null) == null ? 1 : 0
  name       = "${var.rds.identifier}-subnet-group"
  subnet_ids = var.rds.db_subnet_ids
}

data "aws_db_snapshot" "latest" {
  count                  = local.infra_active && var.rds != null && try(var.rds.restore_snapshot_identifier, null) == null && try(var.rds.restore_from_latest_snapshot, true) ? 1 : 0
  db_instance_identifier = try(var.rds.source_instance_identifier, var.rds.identifier)
  most_recent            = true
  include_public         = false
  include_shared         = false
}

locals {
  rds_snapshot_identifier = local.infra_active && var.rds != null ? try(coalesce(
    try(var.rds.restore_snapshot_identifier, null),
    try(data.aws_db_snapshot.latest[0].id, null)
  ), null) : null
}

resource "aws_db_instance" "this" {
  count = local.infra_active && var.rds != null ? 1 : 0

  identifier             = var.rds.identifier
  instance_class         = var.rds.instance_class
  snapshot_identifier    = local.rds_snapshot_identifier
  engine                 = try(var.rds.engine, null)
  engine_version         = try(var.rds.engine_version, null)
  allocated_storage      = try(var.rds.allocated_storage, null)
  db_name                = try(var.rds.db_name, null)
  username               = try(var.rds.username, null)
  password               = random_password.db_master[0].result
  db_subnet_group_name   = try(var.rds.db_subnet_group_name, null) != null ? var.rds.db_subnet_group_name : aws_db_subnet_group.this[0].name
  vpc_security_group_ids = var.rds.vpc_security_group_ids
  publicly_accessible    = try(var.rds.publicly_accessible, false)
  multi_az               = try(var.rds.multi_az, false)
  deletion_protection    = try(var.rds.deletion_protection, false)
  apply_immediately      = try(var.rds.apply_immediately, true)
  skip_final_snapshot    = try(var.rds.skip_final_snapshot, true)
  final_snapshot_identifier = try(var.rds.skip_final_snapshot, true) ? null : coalesce(
    try(var.rds.final_snapshot_identifier, null),
    "${var.rds.identifier}-final-snapshot"
  )
  tags = try(var.rds.tags, {})
}

resource "aws_route53_zone" "rds_private" {
  count = local.infra_active && var.rds != null && try(var.rds.private_zone_name, null) != null ? 1 : 0
  name  = var.rds.private_zone_name

  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "rds_private" {
  count   = local.infra_active && var.rds != null && try(var.rds.private_zone_name, null) != null ? 1 : 0
  zone_id = aws_route53_zone.rds_private[0].zone_id
  name    = var.rds.private_dns_record
  type    = "CNAME"
  ttl     = 60
  records = [aws_db_instance.this[0].address]
}

# Register RabbitMQ EC2 instance(s) as NLB targets
resource "aws_lb_target_group_attachment" "nlb" {
  for_each = local.ec2_messaging_active && var.nlb != null ? toset(try(var.nlb.target_instance_ids, [])) : toset([])

  target_group_arn = aws_lb_target_group.nlb[0].arn
  target_id        = each.value
  port             = var.nlb.target_group.port
}

# Stable private DNS for RabbitMQ NLB — rabbitmq.osc-infra.local
# Reuses the same private zone as RDS so one zone covers all internal infra.
# NOTE: requires rds.private_zone_name to be set.
resource "aws_route53_record" "rabbitmq_private" {
  count   = local.ec2_messaging_active && var.nlb != null && try(var.rds.private_zone_name, null) != null ? 1 : 0
  zone_id = aws_route53_zone.rds_private[0].zone_id
  name    = try(var.nlb.private_dns_record, "rabbitmq")
  type    = "CNAME"
  ttl     = 60
  records = [aws_lb.nlb[0].dns_name]
}

# Amazon MQ is the AWS-native alternative to the RabbitMQ EC2/NLB pair. The
# single-instance profile is intentionally an evaluation/staging profile; the
# application outbox is the source of truth for retrying unpublished commands.
resource "random_password" "rabbitmq" {
  count            = var.amazon_mq != null ? 1 : 0
  length           = 32
  special          = true
  override_special = "!#%&*()-_=+[]{};<>?"
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  count                   = var.amazon_mq != null ? 1 : 0
  name                    = var.amazon_mq.credentials_secret_name
  recovery_window_in_days = 0
  tags                    = try(var.amazon_mq.tags, {})
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  count     = var.amazon_mq != null ? 1 : 0
  secret_id = aws_secretsmanager_secret.rabbitmq[0].id
  secret_string = jsonencode({
    username = var.amazon_mq.username
    password = random_password.rabbitmq[0].result
  })
}

resource "aws_mq_broker" "rabbitmq" {
  count = local.amazon_mq_active ? 1 : 0

  broker_name                = var.amazon_mq.broker_name
  engine_type                = "RABBITMQ"
  engine_version             = var.amazon_mq.engine_version
  host_instance_type         = var.amazon_mq.host_instance_type
  deployment_mode            = "SINGLE_INSTANCE"
  publicly_accessible        = false
  subnet_ids                 = [var.amazon_mq.subnet_ids[0]]
  security_groups            = var.amazon_mq.security_group_ids
  auto_minor_version_upgrade = var.amazon_mq.auto_minor_version_upgrade

  encryption_options {
    use_aws_owned_key = true
  }

  logs {
    general = true
  }

  user {
    username = var.amazon_mq.username
    password = random_password.rabbitmq[0].result
  }

  tags = merge(try(var.amazon_mq.tags, {}), {
    Workload  = "osc-is"
    Lifecycle = "ephemeral-staging"
  })
}
