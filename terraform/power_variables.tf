variable "protect_core_services" {
  type        = bool
  description = "When true, prevents destroy of ECS services/task definitions/log groups managed by this module."
  default     = true
}

variable "manage_hybrid_infra" {
  type        = bool
  description = "When true, this module manages ALB/NLB/NAT/RDS power-state resources."
  default     = false
}

variable "infra_mode" {
  type        = string
  description = "Hybrid infrastructure mode: active (create/keep) or hibernated (destroy expensive resources)."
  default     = "active"

  validation {
    condition     = contains(["active", "hibernated"], lower(var.infra_mode))
    error_message = "infra_mode must be one of: active, hibernated."
  }
}

variable "allow_destroy" {
  type        = bool
  description = "Safety acknowledgment required for hibernated mode destructive actions."
  default     = false
}

variable "alb" {
  description = "Optional ALB configuration for hybrid hibernation control."
  type = object({
    name                       = string
    internal                   = bool
    security_group_ids         = list(string)
    subnet_ids                 = list(string)
    idle_timeout               = optional(number, 60)
    enable_deletion_protection = optional(bool, false)
    listener_port              = optional(number, 443)
    listener_protocol          = optional(string, "HTTPS")
    certificate_arn            = optional(string)
    target_group = object({
      name              = string
      port              = number
      protocol          = string
      target_type       = optional(string, "ip")
      health_check_path = optional(string, "/")
    })
    route53_record_name = optional(string)
    route53_zone_id     = optional(string)
    tags                = optional(map(string), {})
  })
  default = null
}

variable "nlb" {
  description = "Optional NLB configuration for hybrid hibernation control."
  type = object({
    name              = string
    internal          = bool
    subnet_ids        = list(string)
    listener_port     = optional(number, 5672)
    listener_protocol = optional(string, "TCP")
    target_group = object({
      name        = string
      port        = number
      protocol    = string
      target_type = optional(string, "ip")
    })
    route53_record_name = optional(string)
    route53_zone_id     = optional(string)
    tags                = optional(map(string), {})
    # Private DNS record added to the RDS private zone (e.g. "rabbitmq" → rabbitmq.osc-infra.local)
    private_dns_record = optional(string, "rabbitmq")
    # EC2 instance IDs to register as targets in the NLB target group
    target_instance_ids = optional(list(string), [])
  })
  default = null
}

variable "messaging_backend" {
  type        = string
  description = "RabbitMQ runtime: ec2 keeps the existing VM/NLB path; amazon_mq creates a private managed broker."
  default     = "ec2"

  validation {
    condition     = contains(["ec2", "amazon_mq"], lower(var.messaging_backend))
    error_message = "messaging_backend must be one of: ec2, amazon_mq."
  }
}

variable "amazon_mq" {
  description = "Optional private Amazon MQ for RabbitMQ evaluation broker. Use only with messaging_backend=amazon_mq."
  type = object({
    broker_name                = string
    subnet_ids                 = list(string)
    security_group_ids         = list(string)
    host_instance_type         = optional(string, "mq.m7g.medium")
    engine_version             = optional(string, "3.13")
    username                   = optional(string, "osc_service")
    credentials_secret_name    = optional(string, "osc/stg/rabbitmq/credentials")
    auto_minor_version_upgrade = optional(bool, true)
    tags                       = optional(map(string), {})
  })
  default = null

  validation {
    condition     = var.amazon_mq == null || length(var.amazon_mq.subnet_ids) >= 1
    error_message = "amazon_mq.subnet_ids must contain at least one private subnet."
  }
}

variable "nat" {
  description = "Optional NAT Gateway configuration for hybrid hibernation control."
  type = object({
    subnet_id               = string
    private_route_table_ids = list(string)
    allocation_id           = optional(string)
    create_eip              = optional(bool, true)
    eip_tags                = optional(map(string), {})
    nat_tags                = optional(map(string), {})
  })
  default = null
}

variable "rds" {
  description = "Optional RDS restore/delete configuration for hybrid hibernation control."
  type = object({
    identifier                   = string
    instance_class               = string
    db_subnet_ids                = list(string)
    vpc_security_group_ids       = list(string)
    publicly_accessible          = optional(bool, false)
    multi_az                     = optional(bool, false)
    deletion_protection          = optional(bool, false)
    apply_immediately            = optional(bool, true)
    source_instance_identifier   = optional(string)
    restore_from_latest_snapshot = optional(bool, true)
    restore_snapshot_identifier  = optional(string)
    final_snapshot_identifier    = optional(string)
    db_subnet_group_name         = optional(string)
    tags                         = optional(map(string), {})
    # Fresh creation (no snapshot)
    engine            = optional(string)
    engine_version    = optional(string)
    allocated_storage = optional(number)
    db_name           = optional(string)
    username          = optional(string)
    # Terraform-managed master credentials — stable secret name, stable ARN across hibernation
    master_secret_name = optional(string, "osc/stg/db/master")
    # Skip final snapshot on destroy (safe default for dev)
    skip_final_snapshot = optional(bool, true)
    # Private DNS (Terraform creates a new private zone — do not use Cloud Map zones)
    private_zone_name  = optional(string) # e.g. "osc-infra.local"
    private_dns_record = optional(string, "db")
  })
  default = null
}
