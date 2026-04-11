# =============================================================================
# Shared Infrastructure — Main
# Deploys the network (VPC, subnets, SGs) and shared ECS cluster.
# All services deploy INTO these shared resources.
# =============================================================================
# =============================================================================
# 1. Network Stack — VPC, Subnets, Security Groups
# =============================================================================
resource "aws_cloudformation_stack" "network" {
  name          = "ax-ripple-${var.environment}-network"
  template_body = file("${path.module}/cfn/network.yaml")
  parameters = {
    Environment = var.environment
    VpcCidr     = var.vpc_cidr
  }
  capabilities = ["CAPABILITY_NAMED_IAM"]
  tags = {
    Stack = "network"
  }
  lifecycle {
    create_before_destroy = false
  }
  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}
# =============================================================================
# 2. ECS Cluster Stack — Shared cluster, execution role, service discovery
# =============================================================================
resource "aws_cloudformation_stack" "ecs_cluster" {
  name          = "ax-ripple-${var.environment}-ecs-cluster"
  template_body = file("${path.module}/cfn/ecs-cluster.yaml")
  parameters = {
    Environment = var.environment
    VpcId       = aws_cloudformation_stack.network.outputs["VpcId"]
  }
  capabilities = ["CAPABILITY_NAMED_IAM"]
  depends_on   = [aws_cloudformation_stack.network]
  tags = {
    Stack = "ecs-cluster"
  }
  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}
