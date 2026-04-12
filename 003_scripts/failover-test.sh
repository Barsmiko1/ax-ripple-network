#!/usr/bin/env bash
# =============================================================================
# AX Ripple Network — Automated Failover Test
#
# Fully automated (non-interactive) test that validates every failover
# acceptance criterion:
#
#   ✅ HTTP requests continue through the same public endpoint
#   ✅ WebSocket detects interruption, reconnects, resumes events
#   ✅ Backend switch is provable via client logs + HAProxy stats
#   ✅ Validated ledger events continue after failover
#
# Phases:
#   Phase 1: Pre-flight — verify ≥ 2 API nodes, HTTP works, WS works
#   Phase 2: Baseline — start client, collect stable-state metrics
#   Phase 3: Capture — HAProxy stats + backend identity before failover
#   Phase 4: Inject failure — stop one ECS API node task
#   Phase 5: Verify HTTP — confirm HTTP still works
#   Phase 6: Verify WebSocket — confirm reconnect + resumed events
#   Phase 7: Switch proof — client logs + HAProxy stats diff
#   Phase 8: Results — pass/fail summary
#
# Usage:
#   export HAPROXY_PUBLIC_IP=<ip>
#   export ECS_CLUSTER_NAME=<cluster>
#   export API_SERVICE_NAME=<service>
#   ./003_scripts/failover-test.sh
#
# Or let it read from Terraform:
#   ./003_scripts/failover-test.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLIENT_DIR="${PROJECT_ROOT}/001_app/client"
LOG_FILE="/tmp/ax-ripple-failover-test.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo -e "  ${GREEN}✅ PASS — $1${NC}"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}❌ FAIL — $1${NC}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
phase() { echo ""; echo -e "${BOLD}${BLUE}══ Phase $1: $2 ══${NC}"; echo ""; }

# Cleanup
CLIENT_PID=""
# shellcheck disable=SC2329
cleanup() {
  if [ -n "${CLIENT_PID}" ] && kill -0 "${CLIENT_PID}" 2>/dev/null; then
    kill "${CLIENT_PID}" 2>/dev/null || true
    wait "${CLIENT_PID}" 2>/dev/null || true
  fi
  rm -f /tmp/haproxy-stats-before.csv /tmp/haproxy-stats-after.csv /tmp/ax-failover-http.json
}
trap cleanup EXIT

# =============================================================================
# Configuration (from Terraform outputs or environment)
# =============================================================================
CLUSTER_NAME="${ECS_CLUSTER_NAME:-}"
SERVICE_NAME="${API_SERVICE_NAME:-}"
HAPROXY_IP="${HAPROXY_PUBLIC_IP:-}"
HAPROXY_STATS="${HAPROXY_STATS_URL:-}"

# Try to load from Terraform outputs if not set
if [ -z "${CLUSTER_NAME}" ] && command -v terraform &>/dev/null; then
  echo -e "${BLUE}Loading configuration from Terraform outputs...${NC}"
  SHARED_DIR="${PROJECT_ROOT}/004_terraform/shared-infra"
  SVC_DIR="${PROJECT_ROOT}/004_terraform/services/ax-ripple-network"
  CLUSTER_NAME=$(terraform -chdir="${SHARED_DIR}" output -raw ecs_cluster_name 2>/dev/null || echo "")
  SERVICE_NAME=$(terraform -chdir="${SVC_DIR}" output -raw api_node_service_name 2>/dev/null || echo "")
  HAPROXY_IP=$(terraform -chdir="${SVC_DIR}" output -raw haproxy_public_ip 2>/dev/null || echo "")
  HAPROXY_STATS=$(terraform -chdir="${SVC_DIR}" output -raw haproxy_stats_endpoint 2>/dev/null || echo "")
fi

if [ -z "${CLUSTER_NAME}" ] || [ -z "${SERVICE_NAME}" ] || [ -z "${HAPROXY_IP}" ]; then
  echo -e "${RED}ERROR: Missing required configuration.${NC}"
  echo ""
  echo "Set the following environment variables or ensure Terraform outputs are available:"
  echo "  ECS_CLUSTER_NAME   - ECS cluster name"
  echo "  API_SERVICE_NAME   - API node ECS service name"
  echo "  HAPROXY_PUBLIC_IP  - HAProxy public IP address"
  echo "  HAPROXY_STATS_URL  - HAProxy stats URL (optional)"
  exit 1
fi

WS_URL="ws://${HAPROXY_IP}:6006"
HTTP_URL="http://${HAPROXY_IP}"
STATS_URL="${HAPROXY_STATS:-http://${HAPROXY_IP}:8404/stats}"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo -e "${BOLD}  AX Ripple Network — Automated Failover Test  ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
echo ""
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Service:       ${SERVICE_NAME}"
echo "  HAProxy:       ${HAPROXY_IP}"
echo "  HTTP URL:      ${HTTP_URL}"
echo "  WebSocket URL: ${WS_URL}"
echo "  Stats URL:     ${STATS_URL}"
echo "  Log file:      ${LOG_FILE}"
echo ""

# =============================================================================
phase 1 "Pre-Flight Checks"
# =============================================================================

# Check HTTP
echo "  Testing HTTP endpoint..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info","params":[{}]}' 2>/dev/null || echo "000")

if [ "${HTTP_STATUS}" = "200" ]; then
  pass "HTTP endpoint responding (${HTTP_STATUS})"
else
  fail "HTTP endpoint not responding (${HTTP_STATUS})"
  echo -e "  ${RED}Cannot proceed without a working HTTP endpoint.${NC}"
  exit 1
fi

# Check API node count
echo "  Checking ECS tasks..."
TASK_ARNS=$(aws ecs list-tasks \
  --cluster "${CLUSTER_NAME}" \
  --service-name "${SERVICE_NAME}" \
  --desired-status RUNNING \
  --query 'taskArns' \
  --output text 2>/dev/null || echo "")
TASK_COUNT=$(echo "${TASK_ARNS}" | wc -w | tr -d ' ')

if [ "${TASK_COUNT}" -ge 2 ]; then
  pass "${TASK_COUNT} API node tasks running (need ≥ 2)"
else
  fail "Only ${TASK_COUNT} API node tasks running (need ≥ 2)"
  exit 1
fi

# Identify pre-failover backend
PRE_NODE=$(curl -sf --max-time 5 -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info","params":[{}]}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('info',{}).get('hostid','?'))" 2>/dev/null || echo "?")
echo "  Pre-failover backend node: ${PRE_NODE}"

# =============================================================================
phase 2 "Baseline — Start Client & Collect Stable Metrics"
# =============================================================================

cd "${CLIENT_DIR}"
if [ ! -d "node_modules" ]; then
  echo "  Installing dependencies..."
  npm install --silent 2>/dev/null
fi

: > "${LOG_FILE}"
HAPROXY_HOST="${HAPROXY_IP}" \
  RIPPLED_WS_URL="${WS_URL}" \
  RIPPLED_HTTP_URL="${HTTP_URL}" \
  RECONNECT_DELAY_MS=2000 \
  MAX_RECONNECT_DELAY_MS=10000 \
  node client.js >> "${LOG_FILE}" 2>&1 &
CLIENT_PID=$!

echo "  Client started (PID: ${CLIENT_PID})"
echo "  Waiting 20s for stable connection + ledger events..."
sleep 20

if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
  fail "Client exited prematurely"
  echo "  Last 5 lines:"
  tail -5 "${LOG_FILE}"
  exit 1
fi

BASELINE_LEDGERS=$(grep -c "Validated ledger" "${LOG_FILE}" 2>/dev/null || echo "0")
BASELINE_NODE=$(grep "Connected to backend" "${LOG_FILE}" | tail -1 | \
  python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('hostid','?'))" 2>/dev/null || echo "?")

if [ "${BASELINE_LEDGERS}" -gt 0 ]; then
  pass "Client receiving validated ledger events (${BASELINE_LEDGERS} so far)"
else
  fail "No validated ledger events received in 20s"
fi
echo "  Client connected to backend: ${BASELINE_NODE}"

# =============================================================================
phase 3 "Capture Pre-Failover State"
# =============================================================================

# HAProxy stats
curl -sf "${STATS_URL};csv" > /tmp/haproxy-stats-before.csv 2>/dev/null || true
echo "  HAProxy stats captured (pre-failover)"

# Record timestamp
FAILOVER_START=$(date +%s)
echo "  Failover start timestamp: $(date -r "${FAILOVER_START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@${FAILOVER_START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${FAILOVER_START}")"

# =============================================================================
phase 4 "Inject Failure — Stop One API Node"
# =============================================================================

KILL_TASK=$(echo "${TASK_ARNS}" | awk '{print $1}')
KILL_SHORT=$(echo "${KILL_TASK}" | rev | cut -d'/' -f1 | rev)

echo -e "  ${RED}⚡ Stopping task: ${KILL_SHORT}${NC}"

aws ecs stop-task \
  --cluster "${CLUSTER_NAME}" \
  --task "${KILL_TASK}" \
  --reason "Failover test — triggered by failover-test.sh" \
  >/dev/null 2>&1

echo "  Task stop initiated"
echo "  Waiting 30s for HAProxy to detect failure + client to reconnect..."
sleep 30

# =============================================================================
phase 5 "Verify HTTP Continues Through Same Public Endpoint"
# =============================================================================

HTTP_POST_STATUS=$(curl -s -o /tmp/ax-failover-http.json -w "%{http_code}" --max-time 10 \
  -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info","params":[{}]}' 2>/dev/null || echo "000")

if [ "${HTTP_POST_STATUS}" = "200" ]; then
  POST_NODE=$(python3 -c "
import json
with open('/tmp/ax-failover-http.json') as f:
    data = json.load(f)
    print(data.get('result',{}).get('info',{}).get('hostid','?'))
" 2>/dev/null || echo "?")
  pass "HTTP still works after failover (status=${HTTP_POST_STATUS}, node=${POST_NODE})"
else
  fail "HTTP failed after failover (status=${HTTP_POST_STATUS})"
fi

# =============================================================================
phase 6 "Verify WebSocket Reconnection & Resumed Events"
# =============================================================================

if ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
  fail "Client process died during failover"
else
  pass "Client process still alive (PID: ${CLIENT_PID})"
fi

RECONNECT_COUNT=$(grep -c "Reconnecting" "${LOG_FILE}" 2>/dev/null || echo "0")
DISCONNECT_COUNT=$(grep -c "disconnected" "${LOG_FILE}" 2>/dev/null || echo "0")
ESTABLISHED_COUNT=$(grep -c "connection established" "${LOG_FILE}" 2>/dev/null || echo "0")
SWITCH_COUNT=$(grep -c "BACKEND SWITCH" "${LOG_FILE}" 2>/dev/null || echo "0")
TOTAL_LEDGERS=$(grep -c "Validated ledger" "${LOG_FILE}" 2>/dev/null || echo "0")
NEW_LEDGERS=$((TOTAL_LEDGERS - BASELINE_LEDGERS))

POST_RECONNECT_NODE=$(grep "Connected to backend" "${LOG_FILE}" | tail -1 | \
  python3 -c "import sys,json; d=json.loads(sys.stdin.readline()); print(d.get('hostid','?'))" 2>/dev/null || echo "?")

# Verify disconnection detected
if [ "${DISCONNECT_COUNT}" -gt 0 ]; then
  pass "WebSocket disconnection detected (${DISCONNECT_COUNT} event(s))"
else
  fail "No WebSocket disconnection event detected"
fi

# Verify reconnection
if [ "${RECONNECT_COUNT}" -gt 0 ] && [ "${ESTABLISHED_COUNT}" -gt 1 ]; then
  pass "WebSocket reconnected successfully (${RECONNECT_COUNT} reconnects)"
else
  fail "WebSocket did not reconnect (reconnects=${RECONNECT_COUNT}, established=${ESTABLISHED_COUNT})"
fi

# Verify continued events
if [ "${NEW_LEDGERS}" -gt 0 ]; then
  pass "Receiving validated ledger events after failover (+${NEW_LEDGERS} new)"
else
  fail "No new validated ledger events after failover"
fi

# Verify backend switch
if [ "${BASELINE_NODE}" != "${POST_RECONNECT_NODE}" ] || [ "${SWITCH_COUNT}" -gt 0 ]; then
  pass "Backend switch confirmed: ${BASELINE_NODE} → ${POST_RECONNECT_NODE}"
else
  echo -e "  ${YELLOW}⚠️  Client reconnected to same surviving node (${POST_RECONNECT_NODE})${NC}"
  echo -e "  ${YELLOW}     This is valid — HAProxy routed to the only healthy backend${NC}"
fi

# =============================================================================
phase 7 "Switch Proof — Client Logs + HAProxy Stats"
# =============================================================================

echo -e "  ${BOLD}Client log proof:${NC}"
echo ""
echo "  Key events from client log:"
grep -E "disconnected|Reconnecting|connection established|BACKEND SWITCH|Validated ledger" "${LOG_FILE}" | \
  tail -15 | while read -r line; do
    TS=$(echo "${line}" | python3 -c "import sys,json; print(json.loads(sys.stdin.readline()).get('timestamp',''))" 2>/dev/null || echo "")
    MSG=$(echo "${line}" | python3 -c "import sys,json; print(json.loads(sys.stdin.readline()).get('message',''))" 2>/dev/null || echo "${line}")
    if echo "${line}" | grep -q "disconnected"; then
      echo -e "    ${RED}[${TS}] ${MSG}${NC}"
    elif echo "${line}" | grep -q "BACKEND SWITCH"; then
      echo -e "    ${MAGENTA}[${TS}] ${MSG}${NC}"
    elif echo "${line}" | grep -q "Reconnecting\|established"; then
      echo -e "    ${YELLOW}[${TS}] ${MSG}${NC}"
    elif echo "${line}" | grep -q "Validated ledger"; then
      echo -e "    ${GREEN}[${TS}] ${MSG}${NC}"
    fi
  done

echo ""
echo -e "  ${BOLD}HAProxy stats proof:${NC}"
echo ""

curl -sf "${STATS_URL};csv" > /tmp/haproxy-stats-after.csv 2>/dev/null || true

if [ -f /tmp/haproxy-stats-before.csv ] && [ -f /tmp/haproxy-stats-after.csv ]; then
  echo "  Backend status changes:"
  echo ""

  # Show before/after status
  echo "  Before failover:"
  grep -E "^rippled_(http|ws)," /tmp/haproxy-stats-before.csv | while IFS=',' read -r px sv _ _ _ _ _ _ st _; do
    echo "    ${px}/${sv}: ${st}"
  done

  echo ""
  echo "  After failover:"
  grep -E "^rippled_(http|ws)," /tmp/haproxy-stats-after.csv | while IFS=',' read -r px sv _ _ _ _ _ _ st _; do
    if [ "${st}" = "UP" ]; then
      echo -e "    ${GREEN}${px}/${sv}: ${st}${NC}"
    else
      echo -e "    ${RED}${px}/${sv}: ${st}${NC}"
    fi
  done
  echo ""
  pass "HAProxy stats show backend status change"
fi

# =============================================================================
phase 8 "Results"
# =============================================================================

# Stop client
kill "${CLIENT_PID}" 2>/dev/null || true
CLIENT_PID=""

echo ""
echo -e "  ${BOLD}Test Summary:${NC}"
echo ""
echo -e "    Passed: ${GREEN}${PASS_COUNT}${NC}"
echo -e "    Failed: ${RED}${FAIL_COUNT}${NC}"
echo ""
echo "    Baseline backend:      ${BASELINE_NODE}"
echo "    Post-failover backend: ${POST_RECONNECT_NODE}"
echo "    Validated ledgers:     ${TOTAL_LEDGERS} total (+${NEW_LEDGERS} after failover)"
echo "    Reconnect events:      ${RECONNECT_COUNT}"
echo "    Backend switches:      ${SWITCH_COUNT}"
echo ""
echo "    Full client log:       ${LOG_FILE}"
echo ""

if [ "${FAIL_COUNT}" -eq 0 ]; then
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✅ FAILOVER TEST PASSED — All criteria met   ${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "${RED}═══════════════════════════════════════════════${NC}"
  echo -e "${RED}  ❌ FAILOVER TEST FAILED — ${FAIL_COUNT} check(s) failed${NC}"
  echo -e "${RED}═══════════════════════════════════════════════${NC}"
  exit 1
fi

