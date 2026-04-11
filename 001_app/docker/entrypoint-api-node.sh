#!/usr/bin/env bash
# =============================================================================
# Entrypoint — Rippled API (Stock) Node
# =============================================================================
# Handles dynamic configuration at container startup:
#   1. Writes validators.txt (UNL) for private network
#   2. Configures peer discovery via [ips_fixed]
#   3. Starts rippled in foreground
# =============================================================================
set -euo pipefail

CONFIG_FILE="/etc/opt/ripple/rippled.cfg"
VALIDATORS_FILE="/etc/opt/ripple/validators.txt"

echo "[entrypoint] Starting rippled API node..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Write validators.txt (UNL — same list as validators)
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
  echo "[entrypoint] WARN: VALIDATOR_PUBLIC_KEYS not set"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Configure peer discovery via [ips_fixed]
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
# 3. Set network_id for private network isolation
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${NETWORK_ID:-}" ]; then
  echo "" >> "${CONFIG_FILE}"
  echo "[network_id]" >> "${CONFIG_FILE}"
  echo "${NETWORK_ID}" >> "${CONFIG_FILE}"
  echo "[entrypoint] Network ID set to ${NETWORK_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Start rippled
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Configuration complete. Starting rippled..."
echo "[entrypoint]   Config: ${CONFIG_FILE}"
echo "[entrypoint]   Role: api-node"

exec rippled --conf "${CONFIG_FILE}" --fg

