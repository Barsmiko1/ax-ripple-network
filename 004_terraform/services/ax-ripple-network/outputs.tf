# =============================================================================
# AX Ripple Network Service — Outputs
# =============================================================================

# --- ECS Services ---
output "api_node_service_name" {
  description = "API Node ECS Service Name"
  value       = aws_cloudformation_stack.ecs_services.outputs["ApiNodeServiceName"]
}

output "api_node_discovery_endpoint" {
  description = "DNS endpoint for API nodes"
  value       = aws_cloudformation_stack.ecs_services.outputs["ApiNodeDiscoveryEndpoint"]
}

# --- ECR ---
output "validator_ecr_repository_uri" {
  description = "ECR repository URI for validator Docker images"
  value       = aws_cloudformation_stack.ecs_services.outputs["ValidatorECRRepositoryUri"]
}

output "api_node_ecr_repository_uri" {
  description = "ECR repository URI for API node Docker images"
  value       = aws_cloudformation_stack.ecs_services.outputs["ApiNodeECRRepositoryUri"]
}

# --- HAProxy ---
output "haproxy_public_ip" {
  description = "HAProxy public IP address"
  value       = aws_cloudformation_stack.haproxy.outputs["HAProxyPublicIP"]
}

output "haproxy_http_endpoint" {
  description = "HAProxy HTTP endpoint (JSON-RPC)"
  value       = aws_cloudformation_stack.haproxy.outputs["HAProxyHTTPEndpoint"]
}

output "haproxy_ws_endpoint" {
  description = "HAProxy WebSocket endpoint"
  value       = aws_cloudformation_stack.haproxy.outputs["HAProxyWSEndpoint"]
}

output "haproxy_stats_endpoint" {
  description = "HAProxy Stats dashboard"
  value       = aws_cloudformation_stack.haproxy.outputs["HAProxyStatsEndpoint"]
}

# --- Observability ---
output "prometheus_service_arn" {
  description = "Prometheus ECS Service ARN"
  value       = var.enable_observability ? aws_cloudformation_stack.observability[0].outputs["PrometheusServiceArn"] : "disabled"
}

output "grafana_service_arn" {
  description = "Grafana ECS Service ARN"
  value       = var.enable_observability ? aws_cloudformation_stack.observability[0].outputs["GrafanaServiceArn"] : "disabled"
}

