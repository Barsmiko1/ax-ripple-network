#!/usr/bin/env bash
# =============================================================================
# Create ECR Repositories for AX Ripple Network
# =============================================================================
# ECR repos are managed OUTSIDE CloudFormation to prevent delete/recreate
# conflicts when images already exist. Run this once before first deployment.
#
# Usage:
#   ./003_scripts/create-ecr-repos.sh          # defaults to dev
#   ./003_scripts/create-ecr-repos.sh staging   # specify environment
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
REGION="${AWS_REGION:-us-east-1}"

REPOS=(
  "ax-ripple-${ENVIRONMENT}/validator"
  "ax-ripple-${ENVIRONMENT}/api-node"
)

echo "============================================"
echo "  Creating ECR Repositories"
echo "  Environment: ${ENVIRONMENT}"
echo "  Region:      ${REGION}"
echo "============================================"

for repo in "${REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "${repo}" --region "${REGION}" >/dev/null 2>&1; then
    echo "  ⏭️  ${repo} — already exists"
  else
    aws ecr create-repository \
      --repository-name "${repo}" \
      --image-tag-mutability MUTABLE \
      --image-scanning-configuration scanOnPush=true \
      --region "${REGION}" >/dev/null
    echo "  ✅ ${repo} — created"
  fi

  # Apply lifecycle policy — keep last 10 images
  aws ecr put-lifecycle-policy \
    --repository-name "${repo}" \
    --lifecycle-policy-text '{
      "rules": [{
        "rulePriority": 1,
        "description": "Keep last 10 images",
        "selection": { "tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 10 },
        "action": { "type": "expire" }
      }]
    }' \
    --region "${REGION}" >/dev/null
done

echo ""
echo "✅ ECR repositories ready"
echo ""
echo "  Validator: $(aws ecr describe-repositories --repository-names "ax-ripple-${ENVIRONMENT}/validator" --region "${REGION}" --query 'repositories[0].repositoryUri' --output text)"
echo "  API Node:  $(aws ecr describe-repositories --repository-names "ax-ripple-${ENVIRONMENT}/api-node" --region "${REGION}" --query 'repositories[0].repositoryUri' --output text)"

