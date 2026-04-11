#!/usr/bin/env bash
# =============================================================================
# Update ECS Task Definitions with Full Secret ARNs
# =============================================================================
# Registers new revisions of all validator and API node task definitions
# using the FULL Secrets Manager ARNs (including random suffix).
#
# WHY THIS EXISTS:
#   CloudFormation uses !Sub to build partial ARNs without the random suffix
#   AWS appends to every secret (e.g. ax-ripple-dev/validator-seed → -ZO16JB).
#   ECS requires the FULL ARN at task startup to resolve the secret.
#   This script resolves the full ARNs dynamically and registers updated task
#   definitions, then force-redeploys all services.
#
#   Run once after first deploy, or any time secrets are rotated.
#
# Usage:
#   ./003_scripts/update-task-definitions.sh              # defaults to dev + latest
#   ./003_scripts/update-task-definitions.sh staging
#   ./003_scripts/update-task-definitions.sh dev r-1.0.3  # pin specific image tag
# =============================================================================
set -euo pipefail

ENVIRONMENT="${1:-dev}"
IMAGE_TAG="${2:-latest}"
REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "${REGION}")
CLUSTER="ax-ripple-${ENVIRONMENT}"

VALIDATOR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ax-ripple-${ENVIRONMENT}/validator:${IMAGE_TAG}"
API_NODE_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/ax-ripple-${ENVIRONMENT}/api-node:${IMAGE_TAG}"

EXECUTION_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/ax-ripple-${ENVIRONMENT}-ecs-execution"
TASK_ROLE="arn:aws:iam::${ACCOUNT_ID}:role/ax-ripple-${ENVIRONMENT}-rippled-task"

VALIDATOR_LOG_GROUP="/ecs/ax-ripple-${ENVIRONMENT}/validator"
API_NODE_LOG_GROUP="/ecs/ax-ripple-${ENVIRONMENT}/api-node"

PEER_IPS="ripple-validator.${ENVIRONMENT}.local 51235,ripple-api.${ENVIRONMENT}.local 51235"

echo "============================================"
echo "  Updating ECS Task Definitions"
echo "  Environment : ${ENVIRONMENT}"
echo "  Image Tag   : ${IMAGE_TAG}"
echo "  Region      : ${REGION}"
echo "  Account     : ${ACCOUNT_ID}"
echo "============================================"
echo ""

# =============================================================================
# Helper: resolve full secret ARN (includes random suffix) by secret name
# =============================================================================
get_secret_arn() {
  local name="$1"
  local arn
  arn=$(aws secretsmanager describe-secret \
    --secret-id "${name}" \
    --region "${REGION}" \
    --query 'ARN' \
    --output text 2>&1)
  if [[ "${arn}" == *"ResourceNotFoundException"* ]] || [[ -z "${arn}" ]] || [[ "${arn}" == "None" ]]; then
    echo "❌ ERROR: Secret '${name}' not found in Secrets Manager" >&2
    exit 1
  fi
  echo "${arn}"
}

# Resolve all secret ARNs
echo "🔍 Resolving Secrets Manager ARNs..."
SEED_1_ARN=$(get_secret_arn "ax-ripple-${ENVIRONMENT}/validator-seed")
SEED_2_ARN=$(get_secret_arn "ax-ripple-${ENVIRONMENT}/validator-seed-2")
SEED_3_ARN=$(get_secret_arn "ax-ripple-${ENVIRONMENT}/validator-seed-3")
PUBLIC_KEYS_ARN=$(get_secret_arn "ax-ripple-${ENVIRONMENT}/validator-public-keys")

echo "  ✅ validator-seed        : ${SEED_1_ARN}"
echo "  ✅ validator-seed-2      : ${SEED_2_ARN}"
echo "  ✅ validator-seed-3      : ${SEED_3_ARN}"
echo "  ✅ validator-public-keys : ${PUBLIC_KEYS_ARN}"
echo ""

# =============================================================================
# Helper: register a validator task definition and return the ARN
# =============================================================================
register_validator_task() {
  local family="$1"
  local stream_prefix="$2"
  local seed_arn="$3"
  local tmp_file="/tmp/td-${family}.json"

  echo "📋 Registering ${family}..."

  cat > "${tmp_file}" << CONTAINERDEF
[{
  "name": "rippled-validator",
  "image": "${VALIDATOR_IMAGE}",
  "essential": true,
  "portMappings": [{"containerPort": 51235, "protocol": "tcp"}],
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "${VALIDATOR_LOG_GROUP}",
      "awslogs-region": "${REGION}",
      "awslogs-stream-prefix": "${stream_prefix}"
    }
  },
  "healthCheck": {
    "command": ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/51235' 2>/dev/null || exit 1"],
    "interval": 15,
    "timeout": 5,
    "retries": 5,
    "startPeriod": 60
  },
  "environment": [
    {"name": "RIPPLED_ROLE", "value": "validator"},
    {"name": "ENVIRONMENT",  "value": "${ENVIRONMENT}"},
    {"name": "NETWORK_ID",   "value": "10000"},
    {"name": "PEER_IPS",     "value": "${PEER_IPS}"}
  ],
  "secrets": [
    {"name": "VALIDATOR_TOKEN",       "valueFrom": "${seed_arn}"},
    {"name": "VALIDATOR_PUBLIC_KEYS", "valueFrom": "${PUBLIC_KEYS_ARN}"}
  ]
}]
CONTAINERDEF

  local arn
  arn=$(aws ecs register-task-definition \
    --family "${family}" \
    --requires-compatibilities FARGATE \
    --network-mode awsvpc \
    --cpu "1024" \
    --memory "2048" \
    --execution-role-arn "${EXECUTION_ROLE}" \
    --task-role-arn "${TASK_ROLE}" \
    --container-definitions "file://${tmp_file}" \
    --region "${REGION}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

  echo "  ✅ ${arn}"
  rm -f "${tmp_file}"
  # Return the ARN via a global variable (bash doesn't support return values)
  LAST_TASK_DEF_ARN="${arn}"
}

# =============================================================================
# Register validator task definitions (3 — each with unique seed)
# =============================================================================
echo "🔧 Registering Validator Task Definitions..."
register_validator_task "ax-ripple-${ENVIRONMENT}-validator-1" "validator-1" "${SEED_1_ARN}"
TD_V1="${LAST_TASK_DEF_ARN}"
register_validator_task "ax-ripple-${ENVIRONMENT}-validator-2" "validator-2" "${SEED_2_ARN}"
TD_V2="${LAST_TASK_DEF_ARN}"
register_validator_task "ax-ripple-${ENVIRONMENT}-validator-3" "validator-3" "${SEED_3_ARN}"
TD_V3="${LAST_TASK_DEF_ARN}"
echo ""

# =============================================================================
# Register API node task definition
# =============================================================================
echo "🔧 Registering API Node Task Definition..."

cat > /tmp/td-api-node.json << CONTAINERDEF
[{
  "name": "rippled-api",
  "image": "${API_NODE_IMAGE}",
  "essential": true,
  "portMappings": [
    {"containerPort": 5005,  "protocol": "tcp"},
    {"containerPort": 6006,  "protocol": "tcp"},
    {"containerPort": 51235, "protocol": "tcp"}
  ],
  "logConfiguration": {
    "logDriver": "awslogs",
    "options": {
      "awslogs-group": "${API_NODE_LOG_GROUP}",
      "awslogs-region": "${REGION}",
      "awslogs-stream-prefix": "api-node"
    }
  },
  "healthCheck": {
    "command": ["CMD-SHELL", "bash -c 'echo > /dev/tcp/127.0.0.1/51234' 2>/dev/null || exit 1"],
    "interval": 15,
    "timeout": 5,
    "retries": 5,
    "startPeriod": 60
  },
  "environment": [
    {"name": "RIPPLED_ROLE", "value": "api"},
    {"name": "ENVIRONMENT",  "value": "${ENVIRONMENT}"},
    {"name": "NETWORK_ID",   "value": "10000"},
    {"name": "PEER_IPS",     "value": "${PEER_IPS}"}
  ],
  "secrets": [
    {"name": "VALIDATOR_PUBLIC_KEYS", "valueFrom": "${PUBLIC_KEYS_ARN}"}
  ]
}]
CONTAINERDEF

TD_API=$(aws ecs register-task-definition \
  --family "ax-ripple-${ENVIRONMENT}-api-node" \
  --requires-compatibilities FARGATE \
  --network-mode awsvpc \
  --cpu "1024" \
  --memory "2048" \
  --execution-role-arn "${EXECUTION_ROLE}" \
  --task-role-arn "${TASK_ROLE}" \
  --container-definitions "file:///tmp/td-api-node.json" \
  --region "${REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)

echo "  ✅ ${TD_API}"
rm -f /tmp/td-api-node.json
echo ""

# =============================================================================
# Update services to use the NEW task definition ARN explicitly
# (force-new-deployment alone only redeploys the same old revision)
# =============================================================================
echo "🚀 Updating ECS services with new task definition ARNs..."

echo -n "  ax-ripple-${ENVIRONMENT}-validator-1 ... "
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "ax-ripple-${ENVIRONMENT}-validator-1" \
  --task-definition "${TD_V1}" \
  --force-new-deployment \
  --region "${REGION}" \
  --query 'service.serviceName' \
  --output text

echo -n "  ax-ripple-${ENVIRONMENT}-validator-2 ... "
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "ax-ripple-${ENVIRONMENT}-validator-2" \
  --task-definition "${TD_V2}" \
  --force-new-deployment \
  --region "${REGION}" \
  --query 'service.serviceName' \
  --output text

echo -n "  ax-ripple-${ENVIRONMENT}-validator-3 ... "
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "ax-ripple-${ENVIRONMENT}-validator-3" \
  --task-definition "${TD_V3}" \
  --force-new-deployment \
  --region "${REGION}" \
  --query 'service.serviceName' \
  --output text

echo -n "  ax-ripple-${ENVIRONMENT}-api-nodes ... "
aws ecs update-service \
  --cluster "${CLUSTER}" \
  --service "ax-ripple-${ENVIRONMENT}-api-nodes" \
  --task-definition "${TD_API}" \
  --force-new-deployment \
  --region "${REGION}" \
  --query 'service.serviceName' \
  --output text

echo ""
echo "✅ Done — all task definitions updated and services redeploying."
echo ""
echo "  Environment : ${ENVIRONMENT}"
echo "  Image Tag   : ${IMAGE_TAG}"
echo ""
echo "Monitor logs:"
echo "  aws logs tail /ecs/ax-ripple-${ENVIRONMENT}/validator --follow --region ${REGION}"
echo "  aws logs tail /ecs/ax-ripple-${ENVIRONMENT}/api-node  --follow --region ${REGION}"
echo ""
echo "Check service health:"
echo "  aws ecs describe-services --cluster ${CLUSTER} \\"
echo "    --services ax-ripple-${ENVIRONMENT}-validator-1 ax-ripple-${ENVIRONMENT}-validator-2 \\"
echo "               ax-ripple-${ENVIRONMENT}-validator-3 ax-ripple-${ENVIRONMENT}-api-nodes \\"
echo "    --region ${REGION} \\"
echo "    --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount}' --output table"

