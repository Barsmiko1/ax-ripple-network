# =============================================================================
# Atlantis Service — Outputs
# =============================================================================

output "atlantis_service_name" {
  description = "Atlantis ECS Service Name"
  value       = aws_cloudformation_stack.atlantis.outputs["AtlantisServiceName"]
}

output "atlantis_url" {
  description = "Atlantis web UI / webhook URL"
  value       = aws_cloudformation_stack.atlantis.outputs["AtlantisURL"]
}

