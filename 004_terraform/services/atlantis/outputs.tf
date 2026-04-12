# =============================================================================
# Atlantis Service — Outputs
# =============================================================================

output "atlantis_service_name" {
  description = "Atlantis ECS Service Name"
  value       = aws_cloudformation_stack.atlantis.outputs["AtlantisServiceName"]
}

output "atlantis_url" {
  description = "Atlantis web UI / webhook URL (internal)"
  value       = aws_cloudformation_stack.atlantis.outputs["AtlantisURL"]
}

output "atlantis_public_url" {
  description = "Atlantis web UI / webhook URL (via HAProxy)"
  value       = local.atlantis_url
}

