#!/usr/bin/env bash
# =============================================================================
# generate-validator-keys.sh
#
# Generates fresh rippled validator keypairs and tokens for the AX Ripple
# private network. Produces one token per validator node (3 total).
#
# The token (base64 blob) is what rippled reads as [validator_token] in its
# config. The public key (nHXXX) goes into the shared [validators] UNL list.
#
# Usage:
#   ./003_scripts/generate-validator-keys.sh
#   ./003_scripts/generate-validator-keys.sh --push-secrets   # also writes to AWS Secrets Manager
#
# Prerequisites:
#   - Docker (linux/amd64 emulation via Rosetta on Apple Silicon)
#   - AWS CLI + credentials (only required with --push-secrets)
#
# Output:
#   /tmp/validator-keys/validator-{1,2,3}.txt  — PUBLIC_KEY + TOKEN per validator
#
# IMPORTANT:
#   Run this ONCE per environment. Re-running create_token increments the key
#   sequence and all validator services must be redeployed simultaneously.
#   Store the output files OFFLINE and SECURE after uploading to Secrets Manager.
# =============================================================================
set -euo pipefail

DOCKER="${DOCKER:-docker}"
IMAGE="xrpllabsofficial/xrpld:latest"
OUTDIR="/tmp/validator-keys"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PUSH_SECRETS=false

if [[ "${1:-}" == "--push-secrets" ]]; then
  PUSH_SECRETS=true
fi

mkdir -p "${OUTDIR}"

echo "============================================"
echo "  Generating fresh validator keys + tokens"
echo "  Environment : ${ENVIRONMENT}"
echo "  Output dir  : ${OUTDIR}"
echo "============================================"
echo ""

PUBLIC_KEYS=()

for i in 1 2 3; do
  echo "--- Validator ${i} ---"

  RESULT=$(${DOCKER} run --rm --platform linux/amd64 --entrypoint /bin/bash "${IMAGE}" -c "
    set -e
    /opt/ripple/bin/validator-keys create_keys --keyfile /tmp/vkeys.json
    TOKEN=\$(/opt/ripple/bin/validator-keys create_token --keyfile /tmp/vkeys.json | grep -v '^\[' | tr -d '\n ')
    PUBLIC_KEY=\$(python3 -c \"import json; d=json.load(open('/tmp/vkeys.json')); print(d['public_key'])\")
    echo \"PUBLIC_KEY=\${PUBLIC_KEY}\"
    echo \"TOKEN=\${TOKEN}\"
  " 2>&1)

  echo "${RESULT}"
  echo "${RESULT}" > "${OUTDIR}/validator-${i}.txt"

  PUB=$(grep "^PUBLIC_KEY=" "${OUTDIR}/validator-${i}.txt" | cut -d= -f2-)
  PUBLIC_KEYS+=("${PUB}")
  echo ""
done

# Build comma-separated UNL list
ALL_PUBKEYS=$(IFS=','; echo "${PUBLIC_KEYS[*]}")

echo "============================================"
echo "  All public keys (for validators.txt UNL):"
echo "  ${ALL_PUBKEYS}"
echo "  Keys saved to ${OUTDIR}/"
echo "============================================"
echo ""

# ===========================================================================
# Optional: push tokens + public keys directly to AWS Secrets Manager
# ===========================================================================
if [ "${PUSH_SECRETS}" = "true" ]; then
  echo "Pushing secrets to AWS Secrets Manager (environment: ${ENVIRONMENT})..."
  echo ""

  SECRET_NAMES=(
    "ax-ripple-${ENVIRONMENT}/validator-seed"
    "ax-ripple-${ENVIRONMENT}/validator-seed-2"
    "ax-ripple-${ENVIRONMENT}/validator-seed-3"
  )

  for i in 1 2 3; do
    TOKEN=$(grep "^TOKEN=" "${OUTDIR}/validator-${i}.txt" | cut -d= -f2-)
    SECRET_NAME="${SECRET_NAMES[$((i-1))]}"

    # Create or update the secret
    if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" &>/dev/null; then
      aws secretsmanager put-secret-value \
        --secret-id "${SECRET_NAME}" \
        --secret-string "${TOKEN}"
      echo "  Updated : ${SECRET_NAME}"
    else
      aws secretsmanager create-secret \
        --name "${SECRET_NAME}" \
        --description "Rippled validator ${i} token for AX Ripple ${ENVIRONMENT} private network" \
        --secret-string "${TOKEN}"
      echo "  Created : ${SECRET_NAME}"
    fi
  done

  # Push comma-separated public keys (UNL)
  PUBKEYS_SECRET="ax-ripple-${ENVIRONMENT}/validator-public-keys"
  if aws secretsmanager describe-secret --secret-id "${PUBKEYS_SECRET}" &>/dev/null; then
    aws secretsmanager put-secret-value \
      --secret-id "${PUBKEYS_SECRET}" \
      --secret-string "${ALL_PUBKEYS}"
    echo "  Updated : ${PUBKEYS_SECRET}"
  else
    aws secretsmanager create-secret \
      --name "${PUBKEYS_SECRET}" \
      --description "Comma-separated validator public keys (UNL) for AX Ripple ${ENVIRONMENT} private network" \
      --secret-string "${ALL_PUBKEYS}"
    echo "  Created : ${PUBKEYS_SECRET}"
  fi

  echo ""
  echo "All secrets pushed."
  echo ""
  echo "Next step: force-redeploy all validator ECS services to pick up new tokens:"
  echo "  ./003_scripts/update-task-definitions.sh ${ENVIRONMENT}"
else
  echo "Dry run — secrets NOT pushed to AWS."
  echo "Re-run with --push-secrets to upload, e.g.:"
  echo "  ENVIRONMENT=${ENVIRONMENT} ./003_scripts/generate-validator-keys.sh --push-secrets"
fi
