# =============================================================================
# Shared Infrastructure — Terraform Backend
# =============================================================================
terraform {
  backend "s3" {
    bucket         = "ax-ripple-network-terraform-state"
    key            = "shared-infra/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "ax-ripple-network-terraform-locks"
  }
}
