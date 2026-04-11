#!/usr/bin/env bash
# =============================================================================
# Entrypoint — Rippled Validator Node
# =============================================================================
# Handles dynamic configuration at container startup:
#   1. Injects validation_seed from environment or Secrets Manager
#   2. Writes validators.txt (UNL) for private network consensus
#   3. Configures peer discovery via [ips_fixed]
#   4. Starts rippled in foreground
# =============================================================================
set -euo pipefail

CONFIG_FILE="/etc/opt/ripple/rippled.cfg"
VALIDATORS_FILE="/etc/opt/ripple/validators.txt"

echo "[entrypoint] Starting rippled validator node..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Inject validation_seed
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${VALIDATION_SEED:-}" ]; then
  echo "[entrypoint] Injecting validation_seed from environment"
  sed -i "s/PLACEHOLDER_INJECT_AT_DEPLOY/${VALIDATION_SEED}/" "${CONFIG_FILE}"
else
  echo "[entrypoint] ERROR: VALIDATION_SEED not set"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Write validators.txt (UNL — Unique Node List)
#    All validator public keys must be listed so nodes trust each other.
#    VALIDATOR_PUBLIC_KEYS is a comma-separated list passed as env var.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${VALIDATOR_PUBLIC_KEYS:-}" ]; then
  echo "[entrypoint] Writing validators.txt"
  {
    echo "[validators]"
    IFS=',' read -ra KEYS <<< "${VALIDATOR_PUBLIC_KEYS}"
    for key in "${KEYS[@]}"; do
      echo "    ${key}"
    done
  } > "${VALIDATORS_FILE}"
  echo "[entrypoint]   → ${#KEYS[@]} validators configured"
else
  echo "[entrypoint] WARN: VALIDATOR_PUBLIC_KEYS not set — validators.txt will be empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Configure peer discovery via [ips_fixed]
#    PEER_IPS is a comma-separated list of peer addresses (host:port).
#    In ECS, these come from service discovery DNS names.
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${PEER_IPS:-}" ]; then
  echo "[entrypoint] Configuring peer discovery"
  {
    echo ""
    echo "[ips_fixed]"
    IFS=',' read -ra PEERS <<< "${PEER_IPS}"
    for peer in "${PEERS[@]}"; do
      echo "${peer}"
    done
  } >> "${CONFIG_FILE}"
  echo "[entrypoint]   → ${#PEERS[@]} fixed peers configured"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Set network_id for private network isolation
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${NETWORK_ID:-}" ]; then
  echo "" >> "${CONFIG_FILE}"
  echo "[network_id]" >> "${CONFIG_FILE}"
  echo "${NETWORK_ID}" >> "${CONFIG_FILE}"
  echo "[entrypoint] Network ID set to ${NETWORK_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Start rippled
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Configuration complete. Starting rippled..."
echo "[entrypoint]   Config: ${CONFIG_FILE}"
echo "[entrypoint]   Role: validator"

exec rippled --conf "${CONFIG_FILE}" --fg

