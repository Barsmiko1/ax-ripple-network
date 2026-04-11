#!/usr/bin/env bash
# =============================================================================
# AX Ripple Network — Infrastructure & Network Test Script
#
# Validates the deployed private rippled network is healthy:
#   Phase 1: ECS cluster & service health
#   Phase 2: Validator nodes running & peered
#   Phase 3: API nodes running & serving
#   Phase 4: Ledger progression (consensus is working)
#   Phase 5: HAProxy routing (HTTP + WebSocket)
#   Phase 6: HAProxy stats & backend visibility
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - Infrastructure deployed via Terraform/Atlantis
#   - Node.js >= 18 (for WebSocket probe)
#
# Usage:
#   export HAPROXY_PUBLIC_IP=<ip>   # or let script read from Terraform
#   ./003_scripts/test-flow.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo -e "  ${GREEN}✅ PASS — $1${NC}"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}❌ FAIL — $1${NC}"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo -e "  ${YELLOW}⚠️  WARN — $1${NC}"; WARN_COUNT=$((WARN_COUNT + 1)); }
info() { echo -e "  ${CYAN}ℹ️  $1${NC}"; }
header() { echo ""; echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}═══════════════════════════════════════════${NC}"; }

# =============================================================================
# Configuration — load from Terraform outputs or environment
# =============================================================================
CLUSTER_NAME="${ECS_CLUSTER_NAME:-}"
VALIDATOR_SERVICE="${VALIDATOR_SERVICE_NAME:-}"
API_SERVICE="${API_SERVICE_NAME:-}"
HAPROXY_IP="${HAPROXY_PUBLIC_IP:-}"
HAPROXY_STATS="${HAPROXY_STATS_URL:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "${CLUSTER_NAME}" ] && command -v terraform &>/dev/null; then
  echo -e "${BLUE}Loading configuration from Terraform outputs...${NC}"
  SHARED_DIR="${PROJECT_ROOT}/004_terraform/shared-infra"
  SVC_DIR="${PROJECT_ROOT}/004_terraform/services/ax-ripple-network"

  CLUSTER_NAME=$(terraform -chdir="${SHARED_DIR}" output -raw ecs_cluster_name 2>/dev/null || echo "")
  API_SERVICE=$(terraform -chdir="${SVC_DIR}" output -raw api_node_service_name 2>/dev/null || echo "")
  HAPROXY_IP=$(terraform -chdir="${SVC_DIR}" output -raw haproxy_public_ip 2>/dev/null || echo "")
  HAPROXY_STATS=$(terraform -chdir="${SVC_DIR}" output -raw haproxy_stats_endpoint 2>/dev/null || echo "")
fi

if [ -z "${HAPROXY_IP}" ]; then
  echo -e "${RED}ERROR: HAPROXY_PUBLIC_IP not set and cannot read Terraform outputs.${NC}"
  echo "  Set: export HAPROXY_PUBLIC_IP=<ip>"
  exit 1
fi

HTTP_URL="http://${HAPROXY_IP}"
WS_URL="ws://${HAPROXY_IP}:6006"
STATS_URL="${HAPROXY_STATS:-http://${HAPROXY_IP}:8404/stats}"

echo ""
echo -e "${BOLD}AX Ripple Network — Test Flow${NC}"
echo "───────────────────────────────────────────"
echo "  Cluster:     ${CLUSTER_NAME:-<from env>}"
echo "  HAProxy:     ${HAPROXY_IP}"
echo "  HTTP URL:    ${HTTP_URL}"
echo "  WS URL:      ${WS_URL}"
echo "  Stats URL:   ${STATS_URL}"
echo "───────────────────────────────────────────"

# =============================================================================
# Phase 1: ECS Cluster & Services
# =============================================================================
header "Phase 1: ECS Cluster & Service Health"

if [ -n "${CLUSTER_NAME}" ]; then
  # Check cluster exists
  CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "${CLUSTER_NAME}" \
    --query 'clusters[0].status' --output text 2>/dev/null || echo "NOT_FOUND")
  if [ "${CLUSTER_STATUS}" = "ACTIVE" ]; then
    pass "ECS cluster '${CLUSTER_NAME}' is ACTIVE"
  else
    fail "ECS cluster status: ${CLUSTER_STATUS}"
  fi

  # Check API node service
  if [ -n "${API_SERVICE}" ]; then
    API_RUNNING=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" \
      --services "${API_SERVICE}" \
      --query 'services[0].runningCount' --output text 2>/dev/null || echo "0")
    API_DESIRED=$(aws ecs describe-services --cluster "${CLUSTER_NAME}" \
      --services "${API_SERVICE}" \
      --query 'services[0].desiredCount' --output text 2>/dev/null || echo "0")
    if [ "${API_RUNNING}" -ge 2 ]; then
      pass "API node service: ${API_RUNNING}/${API_DESIRED} tasks running"
    else
      fail "API node service: only ${API_RUNNING}/${API_DESIRED} tasks running (need ≥ 2)"
    fi
  fi

  # List all running tasks
  TASK_ARNS=$(aws ecs list-tasks --cluster "${CLUSTER_NAME}" \
    --desired-status RUNNING --query 'taskArns[]' --output text 2>/dev/null || echo "")
  TOTAL_TASKS=$(echo "${TASK_ARNS}" | wc -w | tr -d ' ')
  info "Total running tasks in cluster: ${TOTAL_TASKS}"
else
  warn "ECS cluster name not available — skipping ECS checks"
fi

# =============================================================================
# Phase 2: Validator Nodes (peer-level check via API nodes)
# =============================================================================
header "Phase 2: Validator Node Health"

# Query an API node for peer info — validators show up as peers
PEER_RESPONSE=$(curl -sf --max-time 10 -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"peers","params":[{}]}' 2>/dev/null || echo '{"error":"no_response"}')

PEER_COUNT=$(echo "${PEER_RESPONSE}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    peers = data.get('result', {}).get('peers', [])
    print(len(peers))
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "${PEER_COUNT}" -gt 0 ]; then
  pass "API node sees ${PEER_COUNT} peers (validators + other API nodes)"
else
  warn "API node sees 0 peers — network may still be forming"
fi

# Check server_info for validator count in UNL
SERVER_INFO=$(curl -sf --max-time 10 -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info","params":[{}]}' 2>/dev/null || echo '{}')

QUORUM=$(echo "${SERVER_INFO}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    info = data.get('result', {}).get('info', {})
    q = info.get('validation_quorum', 0)
    print(q)
except:
    print(0)
" 2>/dev/null || echo "0")

if [ "${QUORUM}" -gt 0 ]; then
  pass "Validation quorum: ${QUORUM} (validators are configured)"
else
  warn "Validation quorum not reported — node may still be syncing"
fi

# =============================================================================
# Phase 3: API Nodes — HTTP & WebSocket
# =============================================================================
header "Phase 3: API Node Endpoints"

# HTTP JSON-RPC test
echo -e "  ${CYAN}Testing HTTP endpoint (JSON-RPC via HAProxy :80)...${NC}"
HTTP_STATUS=$(curl -s -o /tmp/ax-test-http.json -w "%{http_code}" --max-time 10 \
  -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"server_info","params":[{}]}' 2>/dev/null || echo "000")

if [ "${HTTP_STATUS}" = "200" ]; then
  SERVER_STATE=$(python3 -c "
import json
with open('/tmp/ax-test-http.json') as f:
    data = json.load(f)
    print(data.get('result',{}).get('info',{}).get('server_state','unknown'))
" 2>/dev/null || echo "unknown")
  HOSTID=$(python3 -c "
import json
with open('/tmp/ax-test-http.json') as f:
    data = json.load(f)
    print(data.get('result',{}).get('info',{}).get('hostid','unknown'))
" 2>/dev/null || echo "unknown")
  pass "HTTP endpoint responding (status=${HTTP_STATUS}, state=${SERVER_STATE}, node=${HOSTID})"
else
  fail "HTTP endpoint not responding (status=${HTTP_STATUS})"
fi

# WebSocket probe — connect, subscribe, wait for one ledger event
echo -e "  ${CYAN}Testing WebSocket endpoint (via HAProxy :6006)...${NC}"
WS_TEST_RESULT=$(timeout 30 node -e "
const WebSocket = require('ws');
const ws = new WebSocket('${WS_URL}');
let done = false;
ws.on('open', () => {
  ws.send(JSON.stringify({id:1, command:'subscribe', streams:['ledger']}));
  ws.send(JSON.stringify({id:2, command:'server_info'}));
});
ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.type === 'ledgerClosed' && !done) {
    done = true;
    console.log('OK:ledger_index=' + msg.ledger_index + ',validated_ledgers=' + (msg.validated_ledgers || 'N/A'));
    ws.close();
  }
  if (msg.result && msg.result.info && msg.result.info.hostid) {
    console.log('HOSTID:' + msg.result.info.hostid);
  }
});
ws.on('error', (e) => { console.log('ERROR:' + e.message); process.exit(1); });
setTimeout(() => { if (!done) { console.log('TIMEOUT'); ws.close(); process.exit(1); } }, 25000);
" 2>/dev/null || echo "ERROR:timeout")

if echo "${WS_TEST_RESULT}" | grep -q "^OK:"; then
  LEDGER_INFO=$(echo "${WS_TEST_RESULT}" | grep "^OK:" | head -1 | sed 's/^OK://')
  WS_HOSTID=$(echo "${WS_TEST_RESULT}" | grep "^HOSTID:" | head -1 | sed 's/^HOSTID://' || echo "unknown")
  pass "WebSocket received validated ledger event (${LEDGER_INFO}, node=${WS_HOSTID})"
else
  fail "WebSocket did not receive ledger event within 25s (${WS_TEST_RESULT})"
fi

# =============================================================================
# Phase 4: Ledger Progression
# =============================================================================
header "Phase 4: Ledger Progression (Consensus)"

COMPLETE_LEDGERS=$(echo "${SERVER_INFO}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('result',{}).get('info',{}).get('complete_ledgers','N/A'))
except:
    print('N/A')
" 2>/dev/null || echo "N/A")

info "Complete ledgers: ${COMPLETE_LEDGERS}"

# Get current ledger index, wait 10s, get again
LEDGER_1=$(curl -sf --max-time 10 -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"ledger","params":[{"ledger_index":"validated"}]}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('ledger_index',0))" 2>/dev/null || echo "0")

echo -e "  ${CYAN}Waiting 10s to check ledger progression...${NC}"
sleep 10

LEDGER_2=$(curl -sf --max-time 10 -X POST "${HTTP_URL}" \
  -H "Content-Type: application/json" \
  -d '{"method":"ledger","params":[{"ledger_index":"validated"}]}' 2>/dev/null | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('ledger_index',0))" 2>/dev/null || echo "0")

if [ "${LEDGER_2}" -gt "${LEDGER_1}" ]; then
  DIFF=$((LEDGER_2 - LEDGER_1))
  pass "Ledger progressing: ${LEDGER_1} → ${LEDGER_2} (+${DIFF} in 10s)"
else
  fail "Ledger NOT progressing: stuck at ${LEDGER_1} (consensus may be broken)"
fi

# =============================================================================
# Phase 5: HAProxy Routing
# =============================================================================
header "Phase 5: HAProxy Load Balancing"

# Make 6 HTTP requests and collect backend node IDs
echo -e "  ${CYAN}Sending 6 HTTP requests to check round-robin...${NC}"
NODES=""
for i in $(seq 1 6); do
  NODE=$(curl -sf --max-time 5 -X POST "${HTTP_URL}" \
    -H "Content-Type: application/json" \
    -d '{"method":"server_info","params":[{}]}' 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('info',{}).get('hostid','?'))" 2>/dev/null || echo "?")
  NODES="${NODES} ${NODE}"
  echo -e "    Request ${i}: → ${NODE}"
done

UNIQUE_NODES=$(echo "${NODES}" | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l | tr -d ' ')
if [ "${UNIQUE_NODES}" -ge 2 ]; then
  pass "HAProxy round-robin distributing to ${UNIQUE_NODES} different backend nodes"
else
  warn "HAProxy only routing to ${UNIQUE_NODES} node(s) — may have only 1 healthy backend"
fi

# =============================================================================
# Phase 6: HAProxy Stats
# =============================================================================
header "Phase 6: HAProxy Stats Dashboard"

STATS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${STATS_URL}" 2>/dev/null || echo "000")
if [ "${STATS_STATUS}" = "200" ]; then
  pass "HAProxy stats dashboard accessible at ${STATS_URL}"

  # Parse CSV stats
  CSV=$(curl -sf "${STATS_URL};csv" 2>/dev/null || echo "")
  if [ -n "${CSV}" ]; then
    echo ""
    echo -e "  ${CYAN}Backend Server Status:${NC}"
    echo "${CSV}" | grep -E "^rippled_(http|ws)," | while IFS=',' read -r pxname svname _ _ _ _ _ _ status _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ rest; do
      if [ "${status}" = "UP" ]; then
        echo -e "    ${GREEN}● ${pxname}/${svname}: UP${NC}"
      else
        echo -e "    ${RED}● ${pxname}/${svname}: ${status}${NC}"
      fi
    done
  fi
else
  warn "HAProxy stats not accessible (status=${STATS_STATUS})"
fi

# =============================================================================
# Results
# =============================================================================
header "TEST RESULTS"

echo ""
echo -e "  ${GREEN}Passed: ${PASS_COUNT}${NC}"
echo -e "  ${RED}Failed: ${FAIL_COUNT}${NC}"
echo -e "  ${YELLOW}Warnings: ${WARN_COUNT}${NC}"
echo ""

rm -f /tmp/ax-test-http.json

if [ "${FAIL_COUNT}" -eq 0 ]; then
  echo -e "${GREEN}═══════════════════════════════════════════"
  echo -e "  ✅ ALL TESTS PASSED"
  echo -e "═══════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "${RED}═══════════════════════════════════════════"
  echo -e "  ❌ ${FAIL_COUNT} TEST(S) FAILED"
  echo -e "═══════════════════════════════════════════${NC}"
  exit 1
fi

