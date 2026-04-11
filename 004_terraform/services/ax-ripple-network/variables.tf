# =============================================================================
# AX Ripple Network Service — Variables
# Service-specific only. Shared infra values come from terraform_remote_state.
# =============================================================================

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region"
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Deployment environment"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "validator_image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag for validator containers (ECR URI is derived)"
}

variable "api_node_image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag for API node containers (ECR URI is derived)"
}

variable "validator_desired_count" {
  type        = number
  default     = 3
  description = "Number of validator nodes"
}

variable "api_node_desired_count" {
  type        = number
  default     = 2
  description = "Number of API nodes"
}

variable "haproxy_instance_type" {
  type        = string
  default     = "t3.small"
  description = "EC2 instance type for HAProxy"
}

variable "haproxy_key_pair_name" {
  type        = string
  default     = ""
  description = "EC2 Key Pair for SSH access to HAProxy (optional)"
}

variable "task_cpu" {
  type        = string
  default     = "1024"
  description = "CPU units for ECS task definitions"
}

variable "task_memory" {
  type        = string
  default     = "2048"
  description = "Memory (MB) for ECS task definitions"
}

variable "enable_observability" {
  type        = bool
  default     = true
  description = "Enable Prometheus + Grafana observability stack"
}
# validator_public_keys is stored in AWS Secrets Manager:
#   ax-ripple-<env>/validator-public-keys
# and injected into ECS tasks via Secrets Manager reference in the task definition.
# It is NOT passed as a Terraform variable to avoid committing sensitive data to the repo.

