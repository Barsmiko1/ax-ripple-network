#!/usr/bin/env bash
# =============================================================================
# provision-grafana-dashboard.sh
# Idempotently provisions:
#   1. Prometheus datasource (fixed UID ax-ripple-prometheus)
#   2. AX Ripple Network observability dashboard
#   3. Cloud Map haproxy service registration (if aws CLI available)
#
# Called automatically by the CI post-deploy job on every push to main.
# Safe to run manually at any time — all operations are idempotent.
#
# Environment variables (all optional — sensible defaults below):
#   GRAFANA_URL          default: http://54.197.47.121:3000
#   GRAFANA_USER         default: admin
#   GRAFANA_PASSWORD     default: admin
#   PROMETHEUS_INTERNAL  default: http://prometheus.dev.local:9090
#   HAPROXY_IP           default: 54.197.47.121
#   ENVIRONMENT          default: dev
#   AWS_REGION           default: us-east-1
# =============================================================================
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-http://54.197.47.121:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-admin}"
PROMETHEUS_INTERNAL="${PROMETHEUS_INTERNAL:-http://prometheus.dev.local:9090}"
HAPROXY_IP="${HAPROXY_IP:-54.197.47.121}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DS_UID="ax-ripple-prometheus"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}[grafana]${NC} $*"; }
ok()   { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }
err()  { echo -e "${RED}❌ $*${NC}"; exit 1; }

# ---------------------------------------------------------------------------
# Helper: Grafana API call via Python (avoids curl/jq version differences)
# ---------------------------------------------------------------------------
gf_api() {
  local method="$1" path="$2" body="${3:-}"
  python3 - << PYEOF
import json, urllib.request, urllib.error, base64, sys
auth = base64.b64encode(b"${GRAFANA_USER}:${GRAFANA_PASSWORD}").decode()
headers = {"Content-Type": "application/json", "Authorization": "Basic " + auth}
body = ${body:-None}
data = json.dumps(body).encode() if body is not None else None
req = urllib.request.Request("${GRAFANA_URL}${path}", data, headers, method="${method}")
try:
    resp = urllib.request.urlopen(req)
    print(resp.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write(f"HTTP {e.code}: {e.read().decode()}\n")
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# 1. Wait for Grafana to be ready
# ---------------------------------------------------------------------------
log "Waiting for Grafana at ${GRAFANA_URL} ..."
for i in $(seq 1 30); do
  STATUS=$(python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('${GRAFANA_URL}/api/health', timeout=4)
    print(json.loads(r.read()).get('database',''))
except: print('')
" 2>/dev/null || echo "")
  if [ "$STATUS" = "ok" ]; then ok "Grafana ready"; break; fi
  [ "$i" -eq 30 ] && err "Grafana not ready after 150s"
  echo "  attempt $i/30 — retrying in 5s..."
  sleep 5
done

# ---------------------------------------------------------------------------
# 2. Register haproxy in Cloud Map (idempotent — needs aws CLI)
# ---------------------------------------------------------------------------
if command -v aws &>/dev/null; then
  log "Ensuring haproxy is registered in Cloud Map..."
  python3 - << PYEOF
import subprocess, json, sys

NS_ID_RESULT = subprocess.run(
    ["aws","servicediscovery","list-namespaces","--region","${AWS_REGION}","--output","json"],
    capture_output=True, text=True)
namespaces = json.loads(NS_ID_RESULT.stdout).get("Namespaces", [])
ns = next((n for n in namespaces if n["Name"] == "${ENVIRONMENT}.local"), None)
if not ns:
    print("  ⚠️  Cloud Map namespace ${ENVIRONMENT}.local not found — skipping")
    sys.exit(0)
NS_ID = ns["Id"]

# Get/create haproxy service
svcs = json.loads(subprocess.run(
    ["aws","servicediscovery","list-services","--region","${AWS_REGION}",
     "--filters", "Name=NAMESPACE_ID,Values="+NS_ID+",Condition=EQ","--output","json"],
    capture_output=True, text=True).stdout).get("Services",[])
haproxy_svc = next((s for s in svcs if s["Name"] == "haproxy"), None)

if not haproxy_svc:
    r = subprocess.run([
        "aws","servicediscovery","create-service","--name","haproxy",
        "--namespace-id", NS_ID,
        "--dns-config","RoutingPolicy=MULTIVALUE,DnsRecords=[{Type=A,TTL=10}]",
        "--health-check-custom-config","FailureThreshold=1",
        "--region","${AWS_REGION}","--output","json"],
        capture_output=True, text=True)
    SVC_ID = json.loads(r.stdout)["Service"]["Id"]
    print(f"  Created Cloud Map service haproxy: {SVC_ID}")
else:
    SVC_ID = haproxy_svc["Id"]
    print(f"  Haproxy Cloud Map service: {SVC_ID}")

# Resolve HAProxy private IP from its public IP via EC2 describe-instances
priv_r = subprocess.run([
    "aws","ec2","describe-instances","--region","${AWS_REGION}",
    "--filters","Name=ip-address,Values=${HAPROXY_IP}","Name=instance-state-name,Values=running",
    "--query","Reservations[0].Instances[0].PrivateIpAddress","--output","text"],
    capture_output=True, text=True)
PRIVATE_IP = priv_r.stdout.strip()
if not PRIVATE_IP or PRIVATE_IP == "None":
    print("  ⚠️  Could not resolve HAProxy private IP — skipping Cloud Map registration")
    sys.exit(0)

# Check if already registered at correct IP
instances = json.loads(subprocess.run(
    ["aws","servicediscovery","list-instances","--service-id",SVC_ID,
     "--region","${AWS_REGION}","--output","json"],
    capture_output=True, text=True).stdout).get("Instances",[])
for inst in instances:
    if inst["Attributes"].get("AWS_INSTANCE_IPV4") == PRIVATE_IP:
        print(f"  Haproxy already registered at {PRIVATE_IP} ✓")
        sys.exit(0)
    # Deregister stale — wait for operation to complete before registering
    dereg = subprocess.run(["aws","servicediscovery","deregister-instance",
        "--service-id",SVC_ID,"--instance-id",inst["Id"],
        "--region","${AWS_REGION}","--output","json"],
        capture_output=True, text=True)
    print(f"  Deregistered stale instance {inst['Id']}")
    # Wait for deregister operation to reach SUCCESS/FAIL before proceeding
    import time
    op_id = json.loads(dereg.stdout).get("OperationId","") if dereg.returncode == 0 else ""
    if op_id:
        for _ in range(30):
            op = json.loads(subprocess.run(
                ["aws","servicediscovery","get-operation","--operation-id",op_id,
                 "--region","${AWS_REGION}","--output","json"],
                capture_output=True, text=True).stdout)
            status = op.get("Operation",{}).get("Status","")
            if status in ("SUCCESS","FAIL"):
                break
            time.sleep(2)

# Register
inst_r = subprocess.run([
    "aws","servicediscovery","register-instance",
    "--service-id",SVC_ID,"--instance-id","haproxy-ec2",
    "--attributes",f"AWS_INSTANCE_IPV4={PRIVATE_IP},AWS_INSTANCE_PORT=8404",
    "--region","${AWS_REGION}","--output","json"],
    capture_output=True, text=True)
if inst_r.returncode == 0:
    print(f"  Registered haproxy in Cloud Map: {PRIVATE_IP}:8404 ✓")
else:
    print(f"  ⚠️  Registration failed: {inst_r.stderr.strip()}")
PYEOF
else
  warn "aws CLI not available — skipping Cloud Map registration"
fi

# ---------------------------------------------------------------------------
# 3. Upsert Prometheus datasource with fixed UID
# ---------------------------------------------------------------------------
log "Configuring Prometheus datasource (uid=${DS_UID})..."
python3 - << PYEOF
import json, urllib.request, urllib.error, base64

GRAFANA = "${GRAFANA_URL}"
DS_UID = "${DS_UID}"
PROM = "${PROMETHEUS_INTERNAL}"
auth = base64.b64encode(b"${GRAFANA_USER}:${GRAFANA_PASSWORD}").decode()
headers = {"Content-Type": "application/json", "Authorization": "Basic " + auth}

def gf(method, path, body=None):
    req = urllib.request.Request(GRAFANA+path,
        json.dumps(body).encode() if body else None, headers, method=method)
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

ds_list = gf("GET", "/api/datasources")
existing = next((d for d in ds_list if d["name"] == "Prometheus"), None)

payload = {"name":"Prometheus","type":"prometheus","uid":DS_UID,"url":PROM,
           "access":"proxy","isDefault":True,
           "jsonData":{"timeInterval":"10s","httpMethod":"POST"}}

if existing:
    r = gf("PUT", f"/api/datasources/{existing['id']}", payload)
    print(f"  Updated datasource uid={r.get('datasource',{}).get('uid',DS_UID)} → {PROM}")
else:
    r = gf("POST", "/api/datasources", payload)
    print(f"  Created datasource → {PROM}")

# Verify connectivity
h = gf("GET", f"/api/datasources/uid/{DS_UID}/health")
status = h.get("status","?")
msg = h.get("message","?")
print(f"  Health: {status} — {msg}")
if status != "OK":
    import sys; sys.exit(1)
PYEOF
ok "Prometheus datasource configured and healthy"

# ---------------------------------------------------------------------------
# 4. Upsert dashboard
# ---------------------------------------------------------------------------
log "Provisioning dashboard..."
python3 - << PYEOF
import json, urllib.request, urllib.error, base64

GRAFANA = "${GRAFANA_URL}"
DS_UID = "${DS_UID}"
auth = base64.b64encode(b"${GRAFANA_USER}:${GRAFANA_PASSWORD}").decode()
headers = {"Content-Type": "application/json", "Authorization": "Basic " + auth}

def gf(method, path, body=None):
    req = urllib.request.Request(GRAFANA+path,
        json.dumps(body).encode() if body else None, headers, method=method)
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        return json.loads(e.read())

def ds():
    return {"type": "prometheus", "uid": DS_UID}

def stat(pid, title, expr, x, w, thresholds, unit="short"):
    return {
        "id": pid, "type": "stat", "title": title,
        "gridPos": {"x": x, "y": 0, "w": w, "h": 4},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"]},
                    "colorMode": "background", "orientation": "auto"},
        "fieldConfig": {"defaults": {"unit": unit, "color": {"mode": "thresholds"},
            "thresholds": {"mode": "absolute", "steps": thresholds}}},
        "targets": [{"expr": expr, "legendFormat": "{{server}}", "datasource": ds()}]
    }

panels = [
    # ── Stat row ─────────────────────────────────────────────────────────────
    stat(1,  "HTTP Backends UP",
         'sum(haproxy_server_status{proxy="rippled_http",state="UP"})', 0, 4,
         [{"value":0,"color":"red"},{"value":1,"color":"yellow"},{"value":2,"color":"green"}]),
    stat(2,  "WS Backends UP",
         'sum(haproxy_server_status{proxy="rippled_ws",state="UP"})', 4, 4,
         [{"value":0,"color":"red"},{"value":1,"color":"yellow"},{"value":2,"color":"green"}]),
    stat(3,  "HTTP Req/s",
         'sum(rate(haproxy_frontend_http_requests_total{proxy="http_front"}[1m]))',
         8, 4, [{"value":0,"color":"blue"}], unit="reqps"),
    stat(4,  "HTTP 5xx/s",
         'sum(rate(haproxy_frontend_http_responses_total{proxy="http_front",code="5xx"}[1m]))',
         12, 4, [{"value":0,"color":"green"},{"value":0.01,"color":"red"}], unit="reqps"),
    stat(5,  "Active WS Sessions",
         'sum(haproxy_backend_current_sessions{proxy="rippled_ws"})',
         16, 4, [{"value":0,"color":"blue"}]),
    stat(6,  "HAProxy Uptime",
         "haproxy_process_uptime_seconds",
         20, 4, [{"value":0,"color":"green"}], unit="s"),

    # ── Failover timeline ─────────────────────────────────────────────────────
    {
        "id": 10, "type": "timeseries",
        "title": "Backend Health — Failover Detection (HTTP + WS)",
        "description": "1=UP, 0=DOWN. Each drop is a failover event.",
        "gridPos": {"x": 0, "y": 4, "w": 24, "h": 8},
        "fieldConfig": {"defaults": {"custom": {"lineWidth": 2, "fillOpacity": 20},
            "min": 0, "max": 1, "color": {"mode": "palette-classic"}}},
        "options": {"tooltip": {"mode": "multi"},
                    "legend": {"displayMode": "list", "placement": "bottom"}},
        "targets": [
            {"expr": 'haproxy_server_status{proxy="rippled_http",state="UP"}',
             "legendFormat": "HTTP/{{server}}", "datasource": ds()},
            {"expr": 'haproxy_server_status{proxy="rippled_ws",state="UP"}',
             "legendFormat": "WS/{{server}}", "datasource": ds()},
        ]
    },

    # ── Request rate + response codes ─────────────────────────────────────────
    {"id": 11, "type": "timeseries", "title": "HTTP Request Rate",
     "gridPos": {"x": 0, "y": 12, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": "sum by (proxy)(rate(haproxy_frontend_http_requests_total[1m]))",
                  "legendFormat": "{{proxy}}", "datasource": ds()}]},
    {"id": 12, "type": "timeseries", "title": "HTTP Response Codes",
     "gridPos": {"x": 12, "y": 12, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": 'sum by (code)(rate(haproxy_frontend_http_responses_total{proxy="http_front"}[1m]))',
                  "legendFormat": "{{code}}", "datasource": ds()}]},

    # ── Sessions + errors ─────────────────────────────────────────────────────
    {"id": 13, "type": "timeseries", "title": "Backend Sessions",
     "gridPos": {"x": 0, "y": 19, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": "haproxy_backend_current_sessions",
                  "legendFormat": "{{proxy}}", "datasource": ds()}]},
    {"id": 14, "type": "timeseries", "title": "Backend Connection Errors & Queue",
     "gridPos": {"x": 12, "y": 19, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [
         {"expr": "sum by (proxy)(rate(haproxy_backend_connection_errors_total[1m]))",
          "legendFormat": "err/{{proxy}}", "datasource": ds()},
         {"expr": "sum by (proxy)(haproxy_backend_current_queue)",
          "legendFormat": "queue/{{proxy}}", "datasource": ds()},
     ]},

    # ── Per-server split (failover proof) ─────────────────────────────────────
    {"id": 15, "type": "timeseries",
     "title": "Per-Server Request Distribution — Failover Proof",
     "description": "During failover one server drops to 0; the survivor absorbs all traffic.",
     "gridPos": {"x": 0, "y": 26, "w": 24, "h": 7},
     "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [
         {"expr": 'sum by (server)(rate(haproxy_server_http_responses_total{proxy="rippled_http"}[1m]))',
          "legendFormat": "{{server}}", "datasource": ds()},
     ]},

    # ── Response time + connection rate ───────────────────────────────────────
    {"id": 16, "type": "timeseries", "title": "Backend Response Time (ms)",
     "gridPos": {"x": 0, "y": 33, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "ms", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": 'haproxy_backend_response_time_average_seconds{proxy=~"rippled.*"} * 1000',
                  "legendFormat": "{{proxy}}", "datasource": ds()}]},
    {"id": 17, "type": "timeseries", "title": "Backend Connection Rate",
     "gridPos": {"x": 12, "y": 33, "w": 12, "h": 7},
     "fieldConfig": {"defaults": {"unit": "connps", "custom": {"lineWidth": 2},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": "sum by (proxy)(rate(haproxy_backend_sessions_total[1m]))",
                  "legendFormat": "{{proxy}}", "datasource": ds()}]},

    # ── Prometheus scrape health ───────────────────────────────────────────────
    {"id": 20, "type": "stat", "title": "Scrape Targets UP",
     "gridPos": {"x": 0, "y": 40, "w": 6, "h": 4},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
     "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
         "thresholds": {"mode": "absolute", "steps": [
             {"value": 0, "color": "red"}, {"value": 1, "color": "green"}]}}},
     "targets": [{"expr": "count(up == 1)", "legendFormat": "up", "datasource": ds()}]},
    {"id": 21, "type": "stat", "title": "Scrape Targets DOWN",
     "gridPos": {"x": 6, "y": 40, "w": 6, "h": 4},
     "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
     "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"},
         "thresholds": {"mode": "absolute", "steps": [
             {"value": 0, "color": "green"}, {"value": 1, "color": "red"}]}}},
     "targets": [{"expr": "count(up == 0) or vector(0)", "legendFormat": "down", "datasource": ds()}]},
    {"id": 22, "type": "timeseries", "title": "Prometheus Scrape Duration",
     "gridPos": {"x": 12, "y": 40, "w": 12, "h": 4},
     "fieldConfig": {"defaults": {"unit": "s", "custom": {"lineWidth": 1},
         "color": {"mode": "palette-classic"}}},
     "targets": [{"expr": "scrape_duration_seconds",
                  "legendFormat": "{{job}}", "datasource": ds()}]},
]

result = gf("POST", "/api/dashboards/db", {
    "dashboard": {
        "id": None, "uid": "ax-ripple-network",
        "title": "AX Ripple Network \u2014 Observability",
        "tags": ["ripple", "haproxy", "failover", "xrpl"],
        "timezone": "browser", "refresh": "10s",
        "time": {"from": "now-30m", "to": "now"},
        "panels": panels
    },
    "folderId": 0, "overwrite": True
})
url = result.get("url", "")
status = result.get("status", result.get("message", "?"))
print(f"  status={status}  url=${GRAFANA_URL}{url}")
if status not in ("success", "Success"):
    import sys; print(f"  full response: {result}", file=sys.stderr); sys.exit(1)
PYEOF
ok "Dashboard provisioned"

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║  AX Ripple Network — Observability                                   ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
printf "║  %-70s║\n" "  Grafana:     ${GRAFANA_URL}/d/ax-ripple-network"
printf "║  %-70s║\n" "  Credentials: ${GRAFANA_USER} / ${GRAFANA_PASSWORD}"
printf "║  %-70s║\n" "  Prometheus:  http://${HAPROXY_IP}:9090/targets"
printf "║  %-70s║\n" "  HAProxy:     http://${HAPROXY_IP}:8404/stats"
echo "╚══════════════════════════════════════════════════════════════════════╝"

