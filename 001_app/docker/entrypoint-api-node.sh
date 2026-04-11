#!/usr/bin/env bash
# =============================================================================
# Entrypoint — Rippled API (Stock) Node
# =============================================================================
# 1. Writes validators.txt with private network UNL
# 2. Configures [ips_fixed] peer discovery
# 3. Sets [network_id] for private network isolation
# 4. Starts rippled in foreground
#
# Ports exposed:
#   51234 — HTTP JSON-RPC (HAProxy backend)
#   6006  — WebSocket    (HAProxy backend)
#   51235 — Peer protocol (internal mesh)
#   5005  — Admin HTTP   (127.0.0.1 only)
# =============================================================================
set -euo pipefail

CONFIG_FILE="/etc/opt/ripple/rippled.cfg"
VALIDATORS_FILE="/etc/opt/ripple/validators.txt"

echo "[entrypoint] Starting rippled API node..."

# ─────────────────────────────────────────────────────────────────────────────
# 1. Write validators.txt (private network UNL)
#    Forcefully overwrite the default mainnet validators.txt from the package.
# ─────────────────────────────────────────────────────────────────────────────
> "${VALIDATORS_FILE}" 2>/dev/null || true

if [ -n "${VALIDATOR_PUBLIC_KEYS:-}" ]; then
  echo "[entrypoint] Writing validators.txt"
  {
    echo "[validators]"
    IFS=',' read -ra KEYS <<< "${VALIDATOR_PUBLIC_KEYS}"
    for key in "${KEYS[@]}"; do
      trimmed=$(echo "${key}" | tr -d '[:space:]')
      [ -n "${trimmed}" ] && echo "    ${trimmed}"
    done
  } > "${VALIDATORS_FILE}"
  echo "[entrypoint]   → ${#KEYS[@]} validators configured"
else
  echo "[entrypoint] WARN: VALIDATOR_PUBLIC_KEYS not set — writing empty validators.txt"
  echo "[validators]" > "${VALIDATORS_FILE}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Configure [ips_fixed] peer discovery
#    PEER_IPS: comma-separated list e.g. "ripple-validator.dev.local 51235,..."
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${PEER_IPS:-}" ]; then
  echo "[entrypoint] Configuring peer discovery"
  {
    echo ""
    echo "[ips_fixed]"
    IFS=',' read -ra PEERS <<< "${PEER_IPS}"
    for peer in "${PEERS[@]}"; do
      trimmed=$(echo "${peer}" | sed 's/^[[:space:]]*//')
      [ -n "${trimmed}" ] && echo "${trimmed}"
    done
  } >> "${CONFIG_FILE}"
  echo "[entrypoint]   → ${#PEERS[@]} fixed peers configured"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Set [network_id] for private network isolation
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "${NETWORK_ID:-}" ]; then
  {
    echo ""
    echo "[network_id]"
    echo "${NETWORK_ID}"
  } >> "${CONFIG_FILE}"
  echo "[entrypoint] Network ID set to ${NETWORK_ID}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Start rippled
# ─────────────────────────────────────────────────────────────────────────────
echo "[entrypoint] Configuration complete. Starting rippled..."
echo "[entrypoint]   Config: ${CONFIG_FILE}"
echo "[entrypoint]   Role: api-node"

exec rippled --conf "${CONFIG_FILE}" --fg

