variable "authorized_account_id" {
  description = "Only this AWS account may be used for the evidence run."
  type        = string
  default     = "269624229733"

  validation {
    condition     = var.authorized_account_id == "269624229733"
    error_message = "The account boundary is fixed to 269624229733."
  }
}

variable "aws_profile" {
  type     = string
  default  = null
  nullable = true
}

variable "runner_public_cidr" {
  description = "Ephemeral CodeBuild egress /32 used only while the runner moves into the runtime VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.runner_public_cidr, 0)) && endswith(var.runner_public_cidr, "/32") && var.runner_public_cidr != "0.0.0.0/0"
    error_message = "runner_public_cidr must be one explicit IPv4 /32."
  }
}

variable "aws_region" {
  type    = string
  default = "us-west-2"

  validation {
    condition     = var.aws_region == "us-west-2"
    error_message = "The approved evidence region is us-west-2."
  }
}

variable "run_id" {
  description = "Unique lower-case identifier for one disposable run."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{8,20}$", var.run_id))
    error_message = "run_id must contain 8-20 lower-case letters or digits."
  }
}

variable "expires_at" {
  description = "RFC3339 hard expiry for the disposable runtime."
  type        = string

  validation {
    condition     = can(timecmp(var.expires_at, timestamp()))
    error_message = "expires_at must be an RFC3339 timestamp."
  }
}

variable "maximum_runtime_hours" {
  description = "Absolute disposable-runtime duration ceiling."
  type        = number
  default     = 72

  validation {
    condition     = var.maximum_runtime_hours > 0 && var.maximum_runtime_hours <= 72
    error_message = "maximum_runtime_hours must be between 1 and the approved 72-hour ceiling."
  }
}

variable "provisioning_ceiling_usd" {
  description = "Absolute campaign provisioning ceiling enforced before apply."
  type        = number
  default     = 200

  validation {
    condition     = var.provisioning_ceiling_usd == 200
    error_message = "The approved absolute provisioning ceiling is USD 200."
  }
}

variable "admin_cidr" {
  description = "Single trusted public IPv4 address allowed to reach the EKS API."
  type        = string

  validation {
    condition = (
      can(cidrhost(var.admin_cidr, 0)) &&
      endswith(var.admin_cidr, "/32") &&
      var.admin_cidr != "0.0.0.0/0"
    )
    error_message = "admin_cidr must be one explicit IPv4 /32 and may not be 0.0.0.0/0."
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"

  validation {
    condition     = var.kubernetes_version == "1.35"
    error_message = "This reviewed experiment is pinned to EKS Kubernetes 1.35."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m7i.large"]
}

variable "node_count" {
  type    = number
  default = 3

  validation {
    condition     = var.node_count == 3
    error_message = "The reviewed experimental topology uses exactly three nodes."
  }
}

variable "rabbitmq_engine_version" {
  type    = string
  default = "4.2"
}

variable "alb_controller_image" {
  description = "Reviewed AWS Load Balancer Controller image reference, pinned by sha256 digest."
  type        = string

  validation {
    condition     = can(regex("^[^[:space:]]+@sha256:[0-9a-f]{64}$", var.alb_controller_image))
    error_message = "alb_controller_image must be an immutable image digest."
  }
}

variable "runtime_role_arns" {
  description = "Exact control-owned role ARNs; runtime Terraform may associate or pass them but cannot create or mutate IAM roles."
  type = object({
    eks_cluster                    = string
    eks_nodes                      = string
    alb_controller                 = string
    api_gateway                    = string
    postgres                       = string
    submission_worker              = string
    submission_listener            = string
    ledger_gateway_nsg             = string
    ledger_gateway_citizen_science = string
    ebs_csi                        = string
  })

  validation {
    condition = alltrue([
      for key, arn in var.runtime_role_arns :
      arn == "arn:aws:iam::269624229733:role/osc-usrse26-${var.run_id}-${replace(key, "_", "-")}"
    ])
    error_message = "Every runtime role must be the exact run-scoped role for its fixed workload key in account 269624229733."
  }
}

variable "rabbitmq_instance_type" {
  type    = string
  default = "mq.m7g.medium"
}
