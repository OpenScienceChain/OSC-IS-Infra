variable "authorized_account_id" {
  type    = string
  default = "269624229733"
  validation {
    condition     = var.authorized_account_id == "269624229733"
    error_message = "The approved account is fixed to 269624229733."
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
    error_message = "The approved runtime and lifecycle region is us-west-2."
  }
}

variable "run_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{8,20}$", var.run_id))
    error_message = "run_id must contain 8-20 lower-case letters or digits."
  }
}

variable "public_hostname" {
  type    = string
  default = "demo.osc-staging.org"
  validation {
    condition     = var.public_hostname == "demo.osc-staging.org"
    error_message = "Changing the approved public hostname requires an explicit owner decision."
  }
}

variable "hosted_zone_id" {
  description = "Existing Route 53 hosted zone ID. The zone is never created or deleted here."
  type        = string
  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be an existing Route 53 zone ID."
  }
}

variable "notification_email" {
  description = "Optional operator email; confirmation is required before notifications work."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.notification_email == null || can(regex("^[^@[:space:]]+@[^@[:space:]]+$", var.notification_email))
    error_message = "notification_email must be null or a valid email address."
  }
}

variable "lifecycle_runner_image" {
  description = "Reviewed lifecycle runner image containing Terraform, kubectl, AWS CLI, and the fixed action entrypoint."
  type        = string
  validation {
    condition     = can(regex("^[^[:space:]]+@sha256:[0-9a-f]{64}$", var.lifecycle_runner_image))
    error_message = "lifecycle_runner_image must be immutable by sha256 digest."
  }
}

variable "artifact_manifest_s3_uri" {
  description = "Versioned, checksum-verified cross-repository deployment manifest consumed by the runner."
  type        = string
  validation {
    condition     = can(regex("^s3://[a-z0-9.-]+/.+/.+[.]json$", var.artifact_manifest_s3_uri))
    error_message = "artifact_manifest_s3_uri must identify a JSON object below a versioned S3 prefix."
  }
}

variable "artifact_manifest_sha256" {
  type = string
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.artifact_manifest_sha256))
    error_message = "artifact_manifest_sha256 must be a lower-case SHA-256 digest."
  }
}

variable "admin_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32") && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be one trusted IPv4 /32."
  }
}

variable "start_at" {
  type    = string
  default = "2026-10-20T08:00:00"
  validation {
    condition     = var.start_at == "2026-10-20T08:00:00"
    error_message = "The approved start is October 20, 2026 at 08:00 America/Los_Angeles."
  }
}

variable "stop_at" {
  type    = string
  default = "2026-10-23T08:00:00"
  validation {
    condition     = var.stop_at == "2026-10-23T08:00:00"
    error_message = "The approved stop is October 23, 2026 at 08:00 America/Los_Angeles."
  }
}

variable "backup_stop_at" {
  type    = string
  default = "2026-10-23T10:00:00"
  validation {
    condition     = var.backup_stop_at == "2026-10-23T10:00:00"
    error_message = "The backup stop must remain two hours after the approved stop."
  }
}

variable "cost_control_mode" {
  type    = string
  default = "TIME_BOUNDED"
  validation {
    condition     = var.cost_control_mode == "TIME_BOUNDED"
    error_message = "The approved cost-control mode is fixed to TIME_BOUNDED."
  }
}

variable "planning_estimate_usd" {
  type    = number
  default = 120
  validation {
    condition     = var.planning_estimate_usd >= 0 && var.planning_estimate_usd <= 200
    error_message = "The pre-deployment planning estimate may not exceed USD 200."
  }
}
