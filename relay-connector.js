const WebSocket = require('ws');
const os = require('os');

const RELAY_URL = (process.env.RELAY_CONNECTOR_URL || '').trim();
const DEVICE_ID = (process.env.RELAY_CONNECTOR_DEVICE_ID || '').trim() || os.hostname();
const DISPLAY_NAME = (process.env.RELAY_CONNECTOR_DISPLAY_NAME || '').trim() || os.hostname();
const PAIRING_ID = (process.env.RELAY_CONNECTOR_PAIRING_ID || '').trim();
const BOOTSTRAP_TOKEN = (process.env.RELAY_CONNECTOR_BOOTSTRAP_TOKEN || '').trim();
const BOOTSTRAP_EXPIRES_AT = (process.env.RELAY_CONNECTOR_BOOTSTRAP_EXPIRES_AT || '').trim();
const LOCAL_BRIDGE_URL = (process.env.RELAY_CONNECTOR_LOCAL_BRIDGE_URL || 'ws://127.0.0.1:4615').trim();
const ROLE = 'mac_connector';
const HEARTBEAT_INTERVAL_MS = Number(process.env.RELAY_CONNECTOR_HEARTBEAT_INTERVAL_MS || 15000);
const RECONNECT_DELAY_MS = Number(process.env.RELAY_CONNECTOR_RECONNECT_DELAY_MS || 3000);

let relaySocket = null;
let localBridgeSocket = null;
let heartbeatTimer = null;
let reconnectTimer = null;
let localBridgeReconnectTimer = null;
let shutdownRequested = false;
let relayRegistered = false;
let localBridgeConnected = false;

function log(message) {
  process.stdout.write(`[relay-connector] ${message}\n`);
}

function clearTimers() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (localBridgeReconnectTimer) {
    clearTimeout(localBridgeReconnectTimer);
    localBridgeReconnectTimer = null;
  }
}

function sendRelayJSON(payload) {
  if (!relaySocket || relaySocket.readyState !== WebSocket.OPEN) return;
  relaySocket.send(JSON.stringify(payload));
}

function sendLocalBridgeText(text) {
  if (!localBridgeSocket || localBridgeSocket.readyState !== WebSocket.OPEN) return false;
  localBridgeSocket.send(text);
  return true;
}

function scheduleReconnect(reason) {
  if (shutdownRequested || reconnectTimer) return;
  log(`relay reconnect scheduled in ${RECONNECT_DELAY_MS}ms (${reason})`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectRelay();
  }, RECONNECT_DELAY_MS);
}

function scheduleLocalBridgeReconnect(reason) {
  if (shutdownRequested || localBridgeReconnectTimer) return;
  log(`local bridge reconnect scheduled in ${RECONNECT_DELAY_MS}ms (${reason})`);
  localBridgeReconnectTimer = setTimeout(() => {
    localBridgeReconnectTimer = null;
    connectLocalBridge();
  }, RECONNECT_DELAY_MS);
}

function startHeartbeat() {
  if (heartbeatTimer) return;
  heartbeatTimer = setInterval(() => {
    sendRelayJSON({
      type: 'heartbeat',
      role: ROLE,
      deviceId: DEVICE_ID,
      sentAt: new Date().toISOString(),
    });
  }, HEARTBEAT_INTERVAL_MS);
}

function relayRegisterPayload() {
  const payload = {
    type: 'register',
    role: ROLE,
    pairingId: PAIRING_ID,
    deviceId: DEVICE_ID,
    displayName: DISPLAY_NAME,
    bootstrapToken: BOOTSTRAP_TOKEN,
    transportVersion: 1,
    capabilities: {
      mode: 'transport',
      directBridgePreserved: true,
      localBridgeURL: LOCAL_BRIDGE_URL,
    },
  };
  if (BOOTSTRAP_EXPIRES_AT) {
    payload.expiresAt = BOOTSTRAP_EXPIRES_AT;
  }
  return payload;
}

function connectLocalBridge() {
  if (shutdownRequested || localBridgeConnected) return;
  if (localBridgeSocket && [WebSocket.CONNECTING, WebSocket.OPEN].includes(localBridgeSocket.readyState)) {
    return;
  }
  log(`connecting to local bridge ${LOCAL_BRIDGE_URL}`);
  localBridgeSocket = new WebSocket(LOCAL_BRIDGE_URL, { perMessageDeflate: false });

  localBridgeSocket.on('open', () => {
    localBridgeConnected = true;
    log('local bridge connected');
  });

  localBridgeSocket.on('message', (raw) => {
    const text = typeof raw === 'string' ? raw : raw.toString('utf8');
    sendRelayJSON({
      type: 'bridge_frame',
      pairingId: PAIRING_ID,
      fromRole: ROLE,
      payload: text,
    });
  });

  localBridgeSocket.on('close', (code, reasonBuffer) => {
    const reason = reasonBuffer ? reasonBuffer.toString('utf8') : '';
    localBridgeConnected = false;
    localBridgeSocket = null;
    log(`local bridge closed (${code}${reason ? `: ${reason}` : ''})`);
    scheduleLocalBridgeReconnect(`close ${code}`);
  });

  localBridgeSocket.on('error', (error) => {
    log(`local bridge error: ${error.message}`);
  });
}

function handleRelayMessage(raw) {
  const text = typeof raw === 'string' ? raw : raw.toString('utf8');
  let payload = null;
  try {
    payload = JSON.parse(text);
  } catch (_) {
    log(`received non-JSON relay frame: ${text.slice(0, 400)}`);
    return;
  }

  switch (payload.type) {
  case 'ping':
    sendRelayJSON({
      type: 'pong',
      role: ROLE,
      deviceId: DEVICE_ID,
      sentAt: new Date().toISOString(),
    });
    return;
  case 'hello':
  case 'registered':
    relayRegistered = true;
    connectLocalBridge();
    break;
  case 'bridge_ready':
    connectLocalBridge();
    break;
  case 'bridge_frame': {
    const bridgePayload = typeof payload.payload === 'string' ? payload.payload : '';
    if (!bridgePayload) return;
    if (!sendLocalBridgeText(bridgePayload)) {
      log('dropping bridge_frame because local bridge is not connected');
      connectLocalBridge();
    }
    return;
  }
  case 'error':
    log(`relay error: ${(payload.message || 'unknown relay error')}`);
    return;
  default:
    break;
  }

  log(`received relay frame: ${text.slice(0, 400)}`);
}

function connectRelay() {
  if (!RELAY_URL) {
    log('relay connector idle: RELAY_CONNECTOR_URL is not configured');
    return;
  }
  if (!PAIRING_ID || !BOOTSTRAP_TOKEN) {
    log('relay connector idle: RELAY_CONNECTOR_PAIRING_ID and RELAY_CONNECTOR_BOOTSTRAP_TOKEN are required');
    return;
  }

  clearTimers();
  relayRegistered = false;
  log(`connecting to relay ${RELAY_URL}`);
  relaySocket = new WebSocket(RELAY_URL, {
    perMessageDeflate: false,
  });

  relaySocket.on('open', () => {
    log('relay connected');
    sendRelayJSON(relayRegisterPayload());
    startHeartbeat();
  });

  relaySocket.on('message', handleRelayMessage);

  relaySocket.on('close', (code, reasonBuffer) => {
    const reason = reasonBuffer ? reasonBuffer.toString('utf8') : '';
    clearTimers();
    relayRegistered = false;
    relaySocket = null;
    log(`relay closed (${code}${reason ? `: ${reason}` : ''})`);
    scheduleReconnect(`close ${code}`);
  });

  relaySocket.on('error', (error) => {
    log(`relay error: ${error.message}`);
  });
}

function shutdown() {
  shutdownRequested = true;
  clearTimers();
  if (relaySocket) {
    try {
      relaySocket.close();
    } catch (_) {}
  }
  if (localBridgeSocket) {
    try {
      localBridgeSocket.close();
    } catch (_) {}
  }
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

connectRelay();
