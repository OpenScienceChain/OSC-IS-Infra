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
  type    = string
  default = "default"
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
  description = "RFC3339 expiry no more than eight hours after apply."
  type        = string

  validation {
    condition     = can(timecmp(var.expires_at, timestamp()))
    error_message = "expires_at must be an RFC3339 timestamp."
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

variable "rabbitmq_instance_type" {
  type    = string
  default = "mq.m7g.medium"
}
