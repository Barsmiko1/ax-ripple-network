# =============================================================================
# AX Ripple Network Service — Main
# Consumes shared-infra outputs, deploys ripple-specific CFN stacks.
# All sensitive values are derived dynamically — nothing hardcoded.
# =============================================================================

# =============================================================================
# Data Sources — derive account ID for ECR URIs
# =============================================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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
  shared     = data.terraform_remote_state.shared.outputs
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # ECR image URIs — derived from account ID, no hardcoding
  validator_image = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/ax-ripple-${var.environment}/validator:${var.validator_image_tag}"
  api_node_image  = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/ax-ripple-${var.environment}/api-node:${var.api_node_image_tag}"
}

# =============================================================================
# 1. ECS Services Stack — Task Defs, Services, ECR Repos, Service Discovery
# =============================================================================
resource "aws_cloudformation_stack" "ecs_services" {
  name = "ax-ripple-${var.environment}-ecs-services"

  template_body = file("${path.module}/cfn/ecs-services.yaml")

  parameters = {
    Environment                 = var.environment
    VpcId                       = local.shared.vpc_id
    PrivateSubnetIds            = local.shared.private_subnet_ids
    RippledPeerSGId             = local.shared.rippled_peer_sg_id
    RippledAPISGId              = local.shared.rippled_api_sg_id
    ECSClusterArn               = local.shared.ecs_cluster_arn
    ECSTaskExecutionRoleArn     = local.shared.ecs_task_execution_role_arn
    ServiceDiscoveryNamespaceId = local.shared.service_discovery_namespace_id
    ValidatorImage              = local.validator_image
    ApiNodeImage                = local.api_node_image
    ValidatorDesiredCount       = tostring(var.validator_desired_count)
    ApiNodeDesiredCount         = tostring(var.api_node_desired_count)
    TaskCpu                     = var.task_cpu
    TaskMemory                  = var.task_memory
    # ValidatorPublicKeys is sourced from Secrets Manager (ax-ripple-<env>/validator-public-keys)
    # and injected directly into containers via ECS task definition Secrets — not passed here.
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  tags = {
    Stack = "ecs-services"
  }

  timeouts {
    create = "20m"
    update = "20m"
    delete = "20m"
  }
}

# =============================================================================
# 2. HAProxy Stack — EC2 with HAProxy for HTTP + WebSocket load balancing
# =============================================================================
resource "aws_cloudformation_stack" "haproxy" {
  name = "ax-ripple-${var.environment}-haproxy"

  template_body = file("${path.module}/cfn/haproxy.yaml")

  parameters = {
    Environment              = var.environment
    VpcId                    = local.shared.vpc_id
    PublicSubnetIds          = local.shared.public_subnet_ids
    HAProxySGId              = local.shared.haproxy_sg_id
    InstanceType             = var.haproxy_instance_type
    KeyPairName              = var.haproxy_key_pair_name
    ApiNodeDiscoveryEndpoint = aws_cloudformation_stack.ecs_services.outputs["ApiNodeDiscoveryEndpoint"]
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  depends_on = [aws_cloudformation_stack.ecs_services]

  tags = {
    Stack = "haproxy"
  }

  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

# =============================================================================
# 3. Observability Stack — Prometheus + Grafana (Conditional)
# =============================================================================
resource "aws_cloudformation_stack" "observability" {
  count = var.enable_observability ? 1 : 0

  name = "ax-ripple-${var.environment}-observability"

  template_body = file("${path.module}/cfn/observability.yaml")

  parameters = {
    Environment              = var.environment
    VpcId                    = local.shared.vpc_id
    PrivateSubnetIds         = local.shared.private_subnet_ids
    PrometheusSGId           = local.shared.prometheus_sg_id
    ECSClusterArn            = local.shared.ecs_cluster_arn
    ApiNodeDiscoveryEndpoint = aws_cloudformation_stack.ecs_services.outputs["ApiNodeDiscoveryEndpoint"]
    HAProxyStatsEndpoint     = aws_cloudformation_stack.haproxy.outputs["HAProxyStatsEndpoint"]
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  depends_on = [
    aws_cloudformation_stack.ecs_services,
    aws_cloudformation_stack.haproxy,
  ]

  tags = {
    Stack = "observability"
  }

  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

