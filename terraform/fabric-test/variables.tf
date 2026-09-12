variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = "osc-fabric-test"
}

variable "kubernetes_version" {
  type        = string
  description = "Pinned EKS minor version under standard support."
  default     = "1.35"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC for the disposable Fabric test cluster."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "At least two private subnets in distinct Availability Zones."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnets in distinct Availability Zones."
  }
}

variable "cluster_public_access_cidrs" {
  type        = list(string)
  description = "Temporary operator CIDRs allowed to reach the authenticated EKS API."
  default     = ["127.0.0.1/32"]

  validation {
    condition     = alltrue([for cidr in var.cluster_public_access_cidrs : cidr != "0.0.0.0/0"])
    error_message = "Do not expose the Fabric test control plane to 0.0.0.0/0."
  }
}

variable "operator_role_arn" {
  type        = string
  description = "GitHub OIDC or operator role granted temporary cluster-admin access."
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_disk_size_gib" {
  type    = number
  default = 40
}

variable "expires_at" {
  type        = string
  description = "Human-readable UTC teardown deadline recorded as a resource tag."
  default     = "set-by-deployment-workflow"
}
