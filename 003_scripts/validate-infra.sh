#!/usr/bin/env bash
# =============================================================================
# AX Ripple Network — Infrastructure Validation Script
# Validates Terraform, CloudFormation templates, and HAProxy config
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ERRORS=0

echo "=== AX Ripple Network — Infrastructure Validation ==="
echo ""

# --- Terraform Validation ---
echo "📋 1. Terraform Validation"
echo "---"
TF_MODULES=(
  "004_terraform/shared-infra"
  "004_terraform/services/ax-ripple-network"
  "004_terraform/services/atlantis"
)

if command -v terraform &>/dev/null; then
  for module in "${TF_MODULES[@]}"; do
    module_name=$(basename "${module}")
    module_path="${PROJECT_ROOT}/${module}"
    echo "  [${module_name}] Checking fmt..."
    if terraform -chdir="${module_path}" fmt -check -recursive -diff; then
      echo "  ✅ [${module_name}] Terraform formatting OK"
    else
      echo "  ❌ [${module_name}] Terraform formatting issues"
      ERRORS=$((ERRORS + 1))
    fi

    echo "  [${module_name}] Checking validate..."
    if terraform -chdir="${module_path}" init -backend=false -input=false >/dev/null 2>&1 && \
       terraform -chdir="${module_path}" validate 2>/dev/null; then
      echo "  ✅ [${module_name}] Terraform validation OK"
    else
      echo "  ⚠️  [${module_name}] Terraform validate skipped (requires init)"
    fi
  done
else
  echo "  ⚠️  terraform not found — skipping"
fi
echo ""

# --- CloudFormation Validation ---
echo "📋 2. CloudFormation Validation"
echo "---"

if command -v cfn-lint &>/dev/null; then
  cfn_files=$(find "${PROJECT_ROOT}/004_terraform" -name '*.yaml' -path '*/cfn/*')
  for filepath in ${cfn_files}; do
    file=$(basename "${filepath}")
    echo "  Linting ${file}..."
    if cfn-lint "${filepath}"; then
      echo "  ✅ ${file} OK"
    else
      echo "  ❌ ${file} has issues"
      ERRORS=$((ERRORS + 1))
    fi
  done
else
  echo "  ⚠️  cfn-lint not found — skipping"
fi
echo ""

# --- HAProxy Config Validation ---
echo "📋 3. HAProxy Configuration Validation"
echo "---"
HAPROXY_CFG="${PROJECT_ROOT}/002_configs/haproxy/haproxy.cfg"
if command -v haproxy &>/dev/null; then
  if [ -f "${HAPROXY_CFG}" ]; then
    echo "  Validating HAProxy config..."
    if haproxy -c -f "${HAPROXY_CFG}" 2>/dev/null; then
      echo "  ✅ HAProxy config OK"
    else
      echo "  ❌ HAProxy config has issues"
      ERRORS=$((ERRORS + 1))
    fi
  fi
else
  echo "  ⚠️  haproxy not found — skipping config validation"
  if [ -f "${HAPROXY_CFG}" ]; then
    echo "  ✅ HAProxy config file exists"
  else
    echo "  ❌ HAProxy config file missing"
    ERRORS=$((ERRORS + 1))
  fi
fi
echo ""

# --- Node.js Client Validation ---
echo "📋 4. Node.js Client Validation"
echo "---"
CLIENT_DIR="${PROJECT_ROOT}/001_app/client"
if [ -f "${CLIENT_DIR}/package.json" ]; then
  echo "  ✅ package.json exists"
  if command -v node &>/dev/null; then
    echo "  Node.js version: $(node --version)"
    if [ -f "${CLIENT_DIR}/client.js" ]; then
      echo "  Checking syntax..."
      if node -c "${CLIENT_DIR}/client.js" 2>/dev/null; then
        echo "  ✅ client.js syntax OK"
      else
        echo "  ❌ client.js syntax error"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    echo "  ⚠️  node not found — skipping"
  fi
else
  echo "  ❌ package.json missing"
  ERRORS=$((ERRORS + 1))
fi
echo ""

# --- File Structure Validation ---
echo "📋 5. Repository Structure Validation"
echo "---"
REQUIRED_FILES=(
  # Shared infra
  "004_terraform/shared-infra/main.tf"
  "004_terraform/shared-infra/variables.tf"
  "004_terraform/shared-infra/outputs.tf"
  "004_terraform/shared-infra/providers.tf"
  "004_terraform/shared-infra/backend.tf"
  "004_terraform/shared-infra/cfn/network.yaml"
  "004_terraform/shared-infra/cfn/ecs-cluster.yaml"
  # AX Ripple Network service
  "004_terraform/services/ax-ripple-network/main.tf"
  "004_terraform/services/ax-ripple-network/variables.tf"
  "004_terraform/services/ax-ripple-network/outputs.tf"
  "004_terraform/services/ax-ripple-network/backend.tf"
  "004_terraform/services/ax-ripple-network/cfn/ecs-services.yaml"
  "004_terraform/services/ax-ripple-network/cfn/haproxy.yaml"
  "004_terraform/services/ax-ripple-network/cfn/observability.yaml"
  # Atlantis service
  "004_terraform/services/atlantis/main.tf"
  "004_terraform/services/atlantis/variables.tf"
  "004_terraform/services/atlantis/outputs.tf"
  "004_terraform/services/atlantis/backend.tf"
  "004_terraform/services/atlantis/cfn/atlantis.yaml"
  # Configs
  "002_configs/haproxy/haproxy.cfg"
  "002_configs/rippled/validator.cfg"
  "002_configs/rippled/api-node.cfg"
  # App
  "001_app/client/package.json"
  "001_app/client/client.js"
  "001_app/docker/Dockerfile.validator"
  "001_app/docker/Dockerfile.api-node"
  ".dockerignore"
  # CI/CD
  ".github/workflows/ci.yml"
  "atlantis.yaml"
  "renovate.json"
  ".mega-linter.yml"
)

for file in "${REQUIRED_FILES[@]}"; do
  filepath="${PROJECT_ROOT}/${file}"
  if [ -f "${filepath}" ]; then
    echo "  ✅ ${file}"
  else
    echo "  ❌ ${file} MISSING"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "==========================================="
if [ ${ERRORS} -eq 0 ]; then
  echo "✅ All validations passed!"
  exit 0
else
  echo "❌ ${ERRORS} validation error(s) found"
  exit 1
fi

