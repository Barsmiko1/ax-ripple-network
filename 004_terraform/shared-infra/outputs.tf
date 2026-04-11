# =============================================================================
# Shared Infrastructure — Outputs
# These are consumed by services via terraform_remote_state
# =============================================================================

# --- Network ---
output "vpc_id" {
  description = "VPC ID"
  value       = aws_cloudformation_stack.network.outputs["VpcId"]
}

output "public_subnet_ids" {
  description = "Public subnet IDs (comma-separated)"
  value       = aws_cloudformation_stack.network.outputs["PublicSubnetIds"]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (comma-separated)"
  value       = aws_cloudformation_stack.network.outputs["PrivateSubnetIds"]
}

# --- Security Groups ---
output "rippled_peer_sg_id" {
  description = "Rippled peer security group ID"
  value       = aws_cloudformation_stack.network.outputs["RippledPeerSGId"]
}

output "rippled_api_sg_id" {
  description = "Rippled API security group ID"
  value       = aws_cloudformation_stack.network.outputs["RippledAPISGId"]
}

output "haproxy_sg_id" {
  description = "HAProxy security group ID"
  value       = aws_cloudformation_stack.network.outputs["HAProxySGId"]
}

output "prometheus_sg_id" {
  description = "Prometheus/Grafana security group ID"
  value       = aws_cloudformation_stack.network.outputs["PrometheusSGId"]
}

output "atlantis_sg_id" {
  description = "Atlantis security group ID"
  value       = aws_cloudformation_stack.network.outputs["AtlantisSGId"]
}

output "atlantis_eip_allocation_id" {
  description = "Allocation ID of the Atlantis Elastic IP (used for EIP association on task start)"
  value       = aws_cloudformation_stack.network.outputs["AtlantisEIPAllocationId"]
}

output "atlantis_public_ip" {
  description = "Fixed public IP for Atlantis — stable across task restarts. Register this as the GitHub webhook URL."
  value       = aws_cloudformation_stack.network.outputs["AtlantisPublicIp"]
}

# --- ECS Cluster ---
output "ecs_cluster_arn" {
  description = "ECS Cluster ARN"
  value       = aws_cloudformation_stack.ecs_cluster.outputs["ClusterArn"]
}

output "ecs_cluster_name" {
  description = "ECS Cluster Name"
  value       = aws_cloudformation_stack.ecs_cluster.outputs["ClusterName"]
}

output "ecs_task_execution_role_arn" {
  description = "Shared ECS Task Execution Role ARN"
  value       = aws_cloudformation_stack.ecs_cluster.outputs["ECSTaskExecutionRoleArn"]
}

output "service_discovery_namespace_id" {
  description = "Service Discovery private DNS namespace ID"
  value       = aws_cloudformation_stack.ecs_cluster.outputs["ServiceDiscoveryNamespaceId"]
}

output "service_discovery_namespace_name" {
  description = "Service Discovery private DNS namespace name"
  value       = aws_cloudformation_stack.ecs_cluster.outputs["ServiceDiscoveryNamespaceName"]
}

