#!/usr/bin/env bash
# =============================================================================
# AX Ripple Network — Bootstrap Terraform Backend
# Creates the S3 bucket and DynamoDB table needed for Terraform state
# =============================================================================

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BUCKET_NAME="ax-ripple-network-terraform-state"
DYNAMODB_TABLE="ax-ripple-network-terraform-locks"

echo "=== Bootstrapping Terraform Backend ==="
echo "Region:    ${REGION}"
echo "Bucket:    ${BUCKET_NAME}"
echo "DynamoDB:  ${DYNAMODB_TABLE}"
echo ""

# --- Create S3 Bucket ---
echo "Creating S3 bucket..."
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "  ✅ Bucket already exists"
else
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET_NAME}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi
  echo "  ✅ Bucket created"
fi


# Enable encryption
echo "Enabling bucket encryption..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'
echo "  ✅ Encryption enabled"

# Block public access
echo "Blocking public access..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  ✅ Public access blocked"

# --- Create DynamoDB Table ---
echo ""
echo "Creating DynamoDB lock table..."
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "  ✅ Table already exists"
else
  aws dynamodb create-table \
    --table-name "${DYNAMODB_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  echo "  Waiting for table to be active..."
  aws dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}" --region "${REGION}"
  echo "  ✅ Table created"
fi

echo ""
echo "=== Bootstrap Complete ==="
echo "You can now run: cd 004_terraform && terraform init"

