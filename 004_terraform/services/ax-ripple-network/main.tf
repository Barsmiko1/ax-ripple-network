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

# Resolve the latest Amazon Linux 2023 AMI ID via SSM at plan time (Terraform)
# so CloudFormation receives a plain AMI ID string and never needs ssm:GetParameters.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
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
  shared     = data.terraform_remote_state.shared.outputs
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  # ECR image URIs — derived from account ID, no hardcoding
  validator_image = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/ax-ripple-${var.environment}/validator:${var.validator_image_tag}"
  api_node_image  = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/ax-ripple-${var.environment}/api-node:${var.api_node_image_tag}"
}

# =============================================================================
# 1. ECS Services Stack — Task Defs, Services, Service Discovery
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
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  # CFN rollback is intentionally ENABLED (default).
  # When a deploy fails CFN rolls back to the last known-good revision.
  # ECS Services and Task Definitions have DeletionPolicy:Retain in the CFN
  # template so rollback never stops/deletes the currently-running tasks —
  # it only reverts the task definition pointer on the service.
  #
  # Terraform taint behaviour:
  #   Taint only occurs when the stack reaches ROLLBACK_COMPLETE (first-ever
  #   create fails).  On an UPDATE failure CFN reaches UPDATE_ROLLBACK_COMPLETE
  #   which Terraform treats as a successful update to the prior state — no
  #   taint, no destroy+recreate on the next run.
  #
  # ignore_changes on template_body:
  #   Terraform re-reads the file on every plan.  Cosmetic encoding differences
  #   (em-dash vs replacement char, trailing newlines) show as a diff and
  #   trigger an UPDATE even when nothing logical changed.
  #   Image / param changes still apply because `parameters` is NOT ignored.
  lifecycle {
    ignore_changes = [template_body]
  }

  tags = {
    Stack = "ecs-services"
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
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
    AmiId                    = data.aws_ssm_parameter.al2023_ami.value
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  lifecycle {
    ignore_changes = [template_body]
  }

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

  lifecycle {
    ignore_changes = [template_body]
  }

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

