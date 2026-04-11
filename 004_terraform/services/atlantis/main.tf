# =============================================================================
# Atlantis Service — Main
# Deploys Atlantis into the shared ECS cluster.
# All sensitive values are derived dynamically — nothing hardcoded.
# =============================================================================

# =============================================================================
# Data Sources — derive account ID and secret ARNs at plan time
# =============================================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_secretsmanager_secret" "github_token" {
  name = var.github_token_secret_name
}

data "aws_secretsmanager_secret" "github_webhook" {
  name = var.github_webhook_secret_name
}

# =============================================================================
# Shared Infrastructure — Remote State
# =============================================================================
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket = "ax-ripple-network-terraform-state"
    key    = "shared-infra/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  shared         = data.terraform_remote_state.shared.outputs
  repo_allowlist = "github.com/${var.github_org}/ax-ripple-network"
}

# =============================================================================
# Atlantis ECS Service Stack
# =============================================================================
resource "aws_cloudformation_stack" "atlantis" {
  name = "ax-ripple-${var.environment}-atlantis"

  template_body = file("${path.module}/cfn/atlantis.yaml")

  parameters = {
    Environment                 = var.environment
    PrivateSubnetIds            = local.shared.private_subnet_ids
    AtlantisSGId                = local.shared.atlantis_sg_id
    ECSClusterArn               = local.shared.ecs_cluster_arn
    ECSTaskExecutionRoleArn     = local.shared.ecs_task_execution_role_arn
    ServiceDiscoveryNamespaceId = local.shared.service_discovery_namespace_id
    AtlantisImage               = var.atlantis_image
    GitHubTokenSecretArn        = data.aws_secretsmanager_secret.github_token.arn
    GitHubWebhookSecretArn      = data.aws_secretsmanager_secret.github_webhook.arn
    AtlantisRepoAllowlist       = local.repo_allowlist
    GitHubUser                  = var.github_user
    TaskCpu                     = var.atlantis_task_cpu
    TaskMemory                  = var.atlantis_task_memory
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  tags = {
    Stack = "atlantis"
  }

  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}
