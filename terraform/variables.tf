variable "region" {
  type        = string
  description = "AWS region for deployment."
}

variable "ecs_cluster_name" {
  type        = string
  description = "ECS cluster name."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID that ECS tasks run in."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for ECS tasks (awsvpc)."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security group IDs for ECS tasks."
}

variable "assign_public_ip" {
  type        = bool
  description = "Assign public IPs to tasks (awsvpc)."
  default     = false
}

variable "runtime_mode" {
  type        = string
  description = "Runtime control mode for ECS and EC2 services: up (run) or down (stop)."
  default     = "up"

  validation {
    condition     = contains(["up", "down"], lower(var.runtime_mode))
    error_message = "runtime_mode must be one of: up, down."
  }
}

variable "services" {
  type = map(object({
    task_def_path          = optional(string)
    task_def_template_path = optional(string)
    task_def_vars          = optional(map(string), {})
    desired_count          = number
    enable_exec            = optional(bool, false)
    alb_container_name     = optional(string)
    alb_container_port     = optional(number)
    cloud_map_service_arn  = optional(string)
  }))
  description = "Map of service names to task definition JSON paths or templates."
}

variable "ec2_instance_ids" {
  type        = list(string)
  description = "EC2 instances to start/stop with runtime_mode (e.g., RabbitMQ/Fabric VMs)."
  default     = []
}

variable "manage_ec2_runtime_state" {
  type        = bool
  description = "When true, Terraform will set EC2 instances in ec2_instance_ids to running/stopped based on runtime_mode."
  default     = true
}

variable "log_retention_in_days" {
  type        = number
  description = "Retention in days for /ecs/* log groups."
  default     = 30
}
