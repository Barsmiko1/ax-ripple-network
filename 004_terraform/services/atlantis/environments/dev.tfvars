aws_region           = "us-east-1"
environment          = "dev"
atlantis_image       = "ghcr.io/runatlantis/atlantis:v0.28.0"
github_org           = "Barsmiko1"
github_user          = "Barsmiko1"
atlantis_task_cpu    = "512"
atlantis_task_memory = "1024"

# atlantis_base_url is NOT set here — it is derived automatically from
# the Elastic IP (AtlantisEIP) allocated in the shared-infra network stack.
# Terraform reads it via: local.shared.atlantis_public_ip
# No IPs are hardcoded anywhere in this repository.

