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
const localBridgeSockets = new Map();
let heartbeatTimer = null;
let reconnectTimer = null;
const localBridgeReconnectTimers = new Map();
let shutdownRequested = false;
let relayRegistered = false;

function log(message) {
  process.stdout.write(`[relay-connector] ${message}\n`);
}

function localBridgeURLForConnector(peerKey = '') {
  try {
    const url = new URL(LOCAL_BRIDGE_URL);
    url.searchParams.set('dexrelayClient', 'relay-connector');
    if (peerKey) {
      url.searchParams.set('dexrelayRemotePeer', peerKey);
    }
    return url.toString();
  } catch (_) {
    const separator = LOCAL_BRIDGE_URL.includes('?') ? '&' : '?';
    const remotePeerParam = peerKey ? `&dexrelayRemotePeer=${encodeURIComponent(peerKey)}` : '';
    return `${LOCAL_BRIDGE_URL}${separator}dexrelayClient=relay-connector${remotePeerParam}`;
  }
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
  for (const timer of localBridgeReconnectTimers.values()) {
    clearTimeout(timer);
  }
  localBridgeReconnectTimers.clear();
}

function sendRelayJSON(payload) {
  if (!relaySocket || relaySocket.readyState !== WebSocket.OPEN) return;
  relaySocket.send(JSON.stringify(payload));
}

function sendLocalBridgeText(text, peerKey = 'default', deviceId = '') {
  const bridge = localBridgeSockets.get(peerKey);
  if (!bridge?.socket || bridge.socket.readyState !== WebSocket.OPEN) {
    connectLocalBridge(peerKey, deviceId);
    return false;
  }
  bridge.socket.send(text);
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

function scheduleLocalBridgeReconnect(peerKey, deviceId, reason) {
  if (shutdownRequested || localBridgeReconnectTimers.has(peerKey)) return;
  log(`local bridge reconnect scheduled in ${RECONNECT_DELAY_MS}ms for ${peerKey} (${reason})`);
  const timer = setTimeout(() => {
    localBridgeReconnectTimers.delete(peerKey);
    connectLocalBridge(peerKey, deviceId);
  }, RECONNECT_DELAY_MS);
  localBridgeReconnectTimers.set(peerKey, timer);
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

function connectLocalBridge(peerKey = 'default', deviceId = '') {
  if (shutdownRequested) return;
  const existing = localBridgeSockets.get(peerKey);
  if (existing?.socket && [WebSocket.CONNECTING, WebSocket.OPEN].includes(existing.socket.readyState)) {
    return;
  }
  const connectorBridgeURL = localBridgeURLForConnector(peerKey);
  log(`connecting to local bridge ${connectorBridgeURL}`);
  const localBridgeSocket = new WebSocket(connectorBridgeURL, { perMessageDeflate: false });
  localBridgeSockets.set(peerKey, {
    socket: localBridgeSocket,
    deviceId,
  });

  localBridgeSocket.on('open', () => {
    log(`local bridge connected for ${peerKey}`);
  });

  localBridgeSocket.on('message', (raw) => {
    const text = typeof raw === 'string' ? raw : raw.toString('utf8');
    sendRelayJSON({
      type: 'bridge_frame',
      pairingId: PAIRING_ID,
      fromRole: ROLE,
      targetPeerKey: peerKey === 'default' ? undefined : peerKey,
      targetDeviceId: deviceId || undefined,
      payload: text,
    });
  });

  localBridgeSocket.on('close', (code, reasonBuffer) => {
    const reason = reasonBuffer ? reasonBuffer.toString('utf8') : '';
    const current = localBridgeSockets.get(peerKey);
    if (current?.socket === localBridgeSocket) {
      localBridgeSockets.delete(peerKey);
    }
    log(`local bridge closed for ${peerKey} (${code}${reason ? `: ${reason}` : ''})`);
    scheduleLocalBridgeReconnect(peerKey, deviceId, `close ${code}`);
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
    const peerKey = String(payload.sourcePeerKey || payload.sourceDeviceId || 'default').trim() || 'default';
    const deviceId = String(payload.sourceDeviceId || '').trim();
    if (!sendLocalBridgeText(bridgePayload, peerKey, deviceId)) {
      log(`dropping bridge_frame because local bridge is not connected for ${peerKey}`);
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
  for (const bridge of localBridgeSockets.values()) {
    try {
      bridge.socket.close();
    } catch (_) {}
  }
  localBridgeSockets.clear();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

connectRelay();
