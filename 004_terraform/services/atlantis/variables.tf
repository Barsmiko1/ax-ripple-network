# =============================================================================
# Atlantis Service — Variables
# No secrets or account IDs here — derived dynamically from AWS data sources.
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

variable "atlantis_image" {
  type        = string
  default     = "ghcr.io/runatlantis/atlantis:v0.28.0"
  description = "Docker image for Atlantis server"
}

variable "github_org" {
  type        = string
  description = "GitHub organization name (e.g. 'my-org')"
}

variable "github_user" {
  type        = string
  description = "GitHub username or bot account for Atlantis to use for PR comments"
}

variable "github_token_secret_name" {
  type        = string
  default     = "atlantis/github-token"
  description = "Name of the Secrets Manager secret for GitHub token"
}

variable "github_webhook_secret_name" {
  type        = string
  default     = "atlantis/webhook-secret"
  description = "Name of the Secrets Manager secret for GitHub webhook secret"
}

variable "atlantis_task_cpu" {
  type        = string
  default     = "512"
  description = "CPU units for Atlantis ECS task"
}

variable "atlantis_task_memory" {
  type        = string
  default     = "1024"
  description = "Memory (MB) for Atlantis ECS task"
}

