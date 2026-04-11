#!/usr/bin/env node

/**
 * AX Ripple Network — WebSocket Failover Test Client
 *
 * Connects to rippled API nodes via HAProxy WebSocket frontend.
 * Subscribes to ledger close events and demonstrates:
 *   - Real-time ledger streaming
 *   - Automatic reconnection with exponential backoff
 *   - Backend failover detection (HAProxy rerouting)
 *
 * Usage:
 *   cp .env.example .env
 *   npm install
 *   npm start
 */

"use strict";

require("dotenv-expand").expand(require("dotenv").config());
const WebSocket = require("ws");

// =============================================================================
// Configuration
// =============================================================================
// HAPROXY_HOST is the primary config — all URLs derive from it.
// Individual URL overrides are supported for advanced use cases.
const HAPROXY_HOST = process.env.HAPROXY_HOST || "localhost";
const WS_URL =
  process.env.RIPPLED_WS_URL || `ws://${HAPROXY_HOST}:6006`;
const HTTP_URL =
  process.env.RIPPLED_HTTP_URL || `http://${HAPROXY_HOST}:80`;
const HAPROXY_STATS_URL =
  process.env.HAPROXY_STATS_URL || `http://${HAPROXY_HOST}:8404/stats`;
const RECONNECT_DELAY = parseInt(process.env.RECONNECT_DELAY_MS, 10) || 2000;
const MAX_RECONNECT_DELAY =
  parseInt(process.env.MAX_RECONNECT_DELAY_MS, 10) || 30000;

// =============================================================================
// State
// =============================================================================
let ws = null;
let reconnectAttempts = 0;
let ledgerCount = 0;
let connectionStartTime = null;
let lastBackendNode = null;
let serverInfoInterval = null;

// =============================================================================
// Logging helpers
// =============================================================================
function log(level, message, data = {}) {
  const timestamp = new Date().toISOString();
  const entry = { timestamp, level, message, ...data };
  console.log(JSON.stringify(entry));
}

function logInfo(message, data) { log("INFO", message, data); }
function logWarn(message, data) { log("WARN", message, data); }
function logError(message, data) { log("ERROR", message, data); }

// =============================================================================
// WebSocket Connection
// =============================================================================
function connect() {
  logInfo("Connecting to rippled via HAProxy", {
    url: WS_URL,
    attempt: reconnectAttempts + 1,
  });

  ws = new WebSocket(WS_URL);
  connectionStartTime = Date.now();

  ws.on("open", () => {
    logInfo("✅ WebSocket connection established", {
      url: WS_URL,
      reconnectAttempts,
    });
    reconnectAttempts = 0;
    subscribeLedger();
    sendServerInfo();

    // Poll server_info every 30s to track which backend we're on
    serverInfoInterval = setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        sendServerInfo();
      }
    }, 30000);
  });

  ws.on("message", (data) => {
    try {
      const message = JSON.parse(data.toString());
      handleMessage(message);
    } catch (err) {
      logError("Failed to parse message", { error: err.message });
    }
  });

  ws.on("close", (code, reason) => {
    if (serverInfoInterval) {
      clearInterval(serverInfoInterval);
      serverInfoInterval = null;
    }

    const duration = connectionStartTime
      ? Math.round((Date.now() - connectionStartTime) / 1000)
      : 0;

    logWarn("❌ WebSocket disconnected", {
      code,
      reason: reason.toString(),
      connectionDurationSec: duration,
      ledgersReceived: ledgerCount,
    });

    scheduleReconnect();
  });

  ws.on("error", (err) => {
    logError("WebSocket error", { error: err.message });
  });
}

// =============================================================================
// Message Handlers
// =============================================================================
function handleMessage(message) {
  // server_info response — identify backend node
  if (message.type === "response" && message.status === "success") {
    if (message.result && message.result.info) {
      const info = message.result.info;
      const currentNode = info.hostid || "unknown";

      if (lastBackendNode && lastBackendNode !== currentNode) {
        logInfo("🔄 BACKEND SWITCH DETECTED", {
          previousNode: lastBackendNode,
          currentNode,
          event: "failover",
        });
      }
      lastBackendNode = currentNode;

      logInfo("📡 Connected to backend node", {
        hostid: currentNode,
        serverState: info.server_state,
        completeLedgers: info.complete_ledgers,
        buildVersion: info.build_version,
      });
    } else {
      logInfo("Subscription confirmed", { result: message.result });
    }
    return;
  }

  // Validated ledger events (rippled sends type: "ledgerClosed" for validated ledgers)
  if (message.type === "ledgerClosed") {
    ledgerCount++;
    logInfo("📒 Validated ledger", {
      ledgerIndex: message.ledger_index,
      ledgerHash: message.ledger_hash,
      txnCount: message.txn_count,
      validatedLedgers: message.validated_ledgers,
      closeTime: message.ledger_time,
      totalReceived: ledgerCount,
      backendNode: lastBackendNode,
    });
    return;
  }

  // Other stream events
  if (message.type) {
    logInfo("📨 Stream event", {
      type: message.type,
      backendNode: lastBackendNode,
    });
  }
}

// =============================================================================
// Commands
// =============================================================================
function subscribeLedger() {
  ws.send(JSON.stringify({ id: 1, command: "subscribe", streams: ["ledger"] }));
  logInfo("Subscribed to ledger stream");
}

function sendServerInfo() {
  ws.send(JSON.stringify({ id: 2, command: "server_info" }));
}

// =============================================================================
// Reconnection Logic (Exponential Backoff)
// =============================================================================
function scheduleReconnect() {
  reconnectAttempts++;
  const delay = Math.min(
    RECONNECT_DELAY * Math.pow(2, reconnectAttempts - 1),
    MAX_RECONNECT_DELAY
  );

  logInfo("⏳ Scheduling reconnect", {
    attempt: reconnectAttempts,
    delayMs: delay,
    maxDelayMs: MAX_RECONNECT_DELAY,
  });

  setTimeout(() => {
    logInfo("🔁 Reconnecting...", { attempt: reconnectAttempts });
    connect();
  }, delay);
}

// =============================================================================
// HTTP Health Check
// =============================================================================
async function checkHTTPHealth() {
  try {
    const response = await fetch(HTTP_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ method: "server_info", params: [{}] }),
    });
    const data = await response.json();
    logInfo("🏥 HTTP health check passed", {
      endpoint: HTTP_URL,
      status: response.status,
      serverState: data?.result?.info?.server_state,
    });
    return true;
  } catch (err) {
    logError("🏥 HTTP health check failed", {
      endpoint: HTTP_URL,
      error: err.message,
    });
    return false;
  }
}

// =============================================================================
// Graceful Shutdown
// =============================================================================
function shutdown(signal) {
  logInfo(`Received ${signal}. Shutting down gracefully...`, {
    totalLedgers: ledgerCount,
  });
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.close(1000, "Client shutting down");
  }
  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

// =============================================================================
// Main
// =============================================================================
async function main() {
  logInfo("=== AX Ripple Network — WebSocket Client ===", {
    haproxyHost: HAPROXY_HOST,
    wsUrl: WS_URL,
    httpUrl: HTTP_URL,
    statsUrl: HAPROXY_STATS_URL,
    reconnectDelay: RECONNECT_DELAY,
    maxReconnectDelay: MAX_RECONNECT_DELAY,
  });

  await checkHTTPHealth();
  connect();
}

main().catch((err) => {
  logError("Fatal error", { error: err.message, stack: err.stack });
  process.exit(1);
});

