const { WebSocketServer } = require('ws');
const { URL } = require('url');

const RELAY_PORT = Number(process.env.RELAY_SERVER_PORT || 4620);
const RELAY_HOST = (process.env.RELAY_SERVER_HOST || '0.0.0.0').trim();
const RELAY_PATH = (process.env.RELAY_SERVER_PATH || '/relay').trim() || '/relay';
const RELAY_REQUIRE_PRELOADED = (process.env.RELAY_SERVER_REQUIRE_PRELOADED || '0').trim() === '1';
const HEARTBEAT_TIMEOUT_MS = Number(process.env.RELAY_SERVER_HEARTBEAT_TIMEOUT_MS || 45000);
const PING_INTERVAL_MS = Number(process.env.RELAY_SERVER_PING_INTERVAL_MS || 15000);

const bootstrapRegistry = loadBootstrapRegistry();
const sockets = new Set();
const pairings = new Map();
let pingTimer = null;

function log(message) {
  process.stdout.write(`[relay-server] ${message}\n`);
}

function loadBootstrapRegistry() {
  const raw = (process.env.RELAY_BOOTSTRAP_REGISTRY_JSON || '').trim();
  if (!raw) return new Map();
  try {
    const parsed = JSON.parse(raw);
    const entries = Array.isArray(parsed) ? parsed : Object.values(parsed);
    return new Map(
      entries
        .map((entry) => normalizeBootstrapEntry(entry))
        .filter(Boolean)
        .map((entry) => [entry.pairingId, entry])
    );
  } catch (error) {
    log(`failed to parse RELAY_BOOTSTRAP_REGISTRY_JSON: ${error.message}`);
    return new Map();
  }
}

function normalizeBootstrapEntry(entry) {
  if (!entry || typeof entry !== 'object') return null;
  const pairingId = String(entry.pairingId || '').trim();
  const bootstrapToken = String(entry.bootstrapToken || '').trim();
  if (!pairingId || !bootstrapToken) return null;
  return {
    pairingId,
    bootstrapToken,
    expiresAt: String(entry.expiresAt || '').trim() || null,
    allowedRoles: Array.isArray(entry.allowedRoles)
      ? entry.allowedRoles.map((role) => String(role || '').trim()).filter(Boolean)
      : null,
    displayName: String(entry.displayName || '').trim() || null,
  };
}

function sendJSON(socket, payload) {
  if (socket.readyState !== socket.OPEN) return;
  socket.send(JSON.stringify(payload));
}

function sendError(socket, code, message) {
  sendJSON(socket, { type: 'error', code, message });
}

function isExpired(expiresAt) {
  if (!expiresAt) return false;
  const timestamp = Date.parse(expiresAt);
  return Number.isFinite(timestamp) && timestamp <= Date.now();
}

function getPairingState(pairingId) {
  let state = pairings.get(pairingId);
  if (!state) {
    state = {
      bootstrapToken: null,
      expiresAt: null,
      peers: new Map(),
      createdAt: new Date().toISOString(),
    };
    pairings.set(pairingId, state);
  }
  return state;
}

function peerKeyFor(role, deviceId) {
  const normalizedRole = String(role || '').trim();
  const normalizedDeviceID = String(deviceId || '').trim();
  return normalizedRole === 'ios_client'
    ? `${normalizedRole}:${normalizedDeviceID}`
    : normalizedRole;
}

function peersForRole(state, role) {
  return Array.from(state.peers.values()).filter((peer) => peer.role === role);
}

function firstPeerForRole(state, role) {
  return peersForRole(state, role)[0] || null;
}

function registerSocketForPairing(socket, payload) {
  const role = String(payload.role || '').trim();
  const pairingId = String(payload.pairingId || '').trim();
  const deviceId = String(payload.deviceId || '').trim();
  const displayName = String(payload.displayName || '').trim() || deviceId;
  const bootstrapToken = String(payload.bootstrapToken || '').trim();
  const expiresAt = String(payload.expiresAt || '').trim() || null;

  if (!role || !pairingId || !deviceId || !bootstrapToken) {
    sendError(socket, 'invalid_register', 'role, pairingId, deviceId, and bootstrapToken are required');
    return;
  }

  const preloaded = bootstrapRegistry.get(pairingId);
  if (preloaded) {
    if (preloaded.bootstrapToken !== bootstrapToken) {
      sendError(socket, 'token_mismatch', 'bootstrap token did not match the preloaded pairing');
      return;
    }
    if (isExpired(preloaded.expiresAt)) {
      sendError(socket, 'pairing_expired', 'preloaded pairing has expired');
      return;
    }
    if (preloaded.allowedRoles && !preloaded.allowedRoles.includes(role)) {
      sendError(socket, 'role_not_allowed', `role ${role} is not allowed for this pairing`);
      return;
    }
  } else if (RELAY_REQUIRE_PRELOADED) {
    sendError(socket, 'pairing_unknown', 'pairing is not preloaded on this relay');
    return;
  }

  const state = getPairingState(pairingId);
  if (state.bootstrapToken && state.bootstrapToken !== bootstrapToken) {
    sendError(socket, 'token_mismatch', 'bootstrap token did not match existing pairing state');
    return;
  }
  if (!state.bootstrapToken) {
    state.bootstrapToken = bootstrapToken;
    state.expiresAt = expiresAt || preloaded?.expiresAt || null;
  }
  if (isExpired(state.expiresAt)) {
    sendError(socket, 'pairing_expired', 'pairing has expired');
    return;
  }

  const peerKey = peerKeyFor(role, deviceId);
  const existingPeer = state.peers.get(peerKey);
  if (existingPeer && existingPeer.socket !== socket) {
    try {
      sendError(existingPeer.socket, 'peer_replaced', `new ${role} peer registered for pairing ${pairingId}`);
      existingPeer.socket.close(4009, 'peer replaced');
    } catch (_) {}
  }
  if (role !== 'ios_client') {
    const existingRolePeer = firstPeerForRole(state, role);
    if (existingRolePeer && existingRolePeer.socket !== socket && existingRolePeer !== existingPeer) {
      state.peers.delete(existingRolePeer.peerKey);
      try {
        sendError(existingRolePeer.socket, 'peer_replaced', `new ${role} peer registered for pairing ${pairingId}`);
        existingRolePeer.socket.close(4009, 'peer replaced');
      } catch (_) {}
    }
  }

  socket.meta = {
    peerKey,
    role,
    pairingId,
    deviceId,
    displayName,
    connectedAt: new Date().toISOString(),
    lastSeenAt: Date.now(),
  };

  state.peers.set(peerKey, {
    socket,
    peerKey,
    role,
    deviceId,
    displayName,
    connectedAt: socket.meta.connectedAt,
    lastSeenAt: socket.meta.lastSeenAt,
  });

  sendJSON(socket, {
    type: 'hello',
    message: `Relay control plane ready for pairing ${pairingId}`,
    role,
    pairingId,
    peerKey,
    peers: describePeers(state),
  });
  sendJSON(socket, {
    type: 'registered',
    message: `${role} registered on relay scaffold`,
    role,
    pairingId,
    peerKey,
    peers: describePeers(state),
  });
  broadcastPairingState(pairingId, `${role} connected`);
}

function describePeers(state) {
  return Array.from(state.peers.values()).map((peer) => ({
    peerKey: peer.peerKey,
    role: peer.role,
    deviceId: peer.deviceId,
    displayName: peer.displayName,
    connectedAt: peer.connectedAt,
  }));
}

function broadcastPairingState(pairingId, message) {
  const state = pairings.get(pairingId);
  if (!state) return;
  const payload = {
    type: 'peer_state',
    pairingId,
    message,
    peers: describePeers(state),
  };
  for (const peer of state.peers.values()) {
    sendJSON(peer.socket, payload);
  }
  maybeBroadcastReady(pairingId);
}

function maybeBroadcastReady(pairingId) {
  const state = pairings.get(pairingId);
  if (!state) return;
  const iosPeers = peersForRole(state, 'ios_client');
  const macPeer = firstPeerForRole(state, 'mac_connector');
  if (iosPeers.length === 0 || !macPeer) return;
  const payload = {
    type: 'bridge_ready',
    pairingId,
    message: 'Relay bridge path is ready',
    peers: describePeers(state),
  };
  for (const iosPeer of iosPeers) {
    sendJSON(iosPeer.socket, payload);
  }
  sendJSON(macPeer.socket, payload);
}

function removeSocket(socket) {
  sockets.delete(socket);
  const meta = socket.meta;
  if (!meta?.pairingId || !meta.role) return;
  const state = pairings.get(meta.pairingId);
  if (!state) return;
  const current = state.peers.get(meta.peerKey || peerKeyFor(meta.role, meta.deviceId));
  if (current?.socket === socket) {
    state.peers.delete(current.peerKey);
  }
  if (state.peers.size === 0) {
    pairings.delete(meta.pairingId);
    return;
  }
  broadcastPairingState(meta.pairingId, `${meta.role} disconnected`);
}

function handleFrame(socket, text) {
  let payload;
  try {
    payload = JSON.parse(text);
  } catch (_) {
    sendError(socket, 'invalid_json', 'frame must be valid JSON');
    return;
  }

  const type = String(payload.type || '').trim();
  socket.meta = socket.meta || {};
  socket.meta.lastSeenAt = Date.now();

  switch (type) {
  case 'register':
    registerSocketForPairing(socket, payload);
    break;
  case 'bridge_frame': {
    const pairingId = socket.meta?.pairingId;
    const role = socket.meta?.role;
    if (!pairingId || !role) {
      sendError(socket, 'not_registered', 'register before sending bridge frames');
      return;
    }
    const state = pairings.get(pairingId);
    if (!state) {
      sendError(socket, 'pairing_unknown', 'pairing is not active on this relay');
      return;
    }
    const bridgePayload = typeof payload.payload === 'string' ? payload.payload : '';
    if (role === 'ios_client') {
      const targetPeer = firstPeerForRole(state, 'mac_connector');
      if (!targetPeer) {
        sendError(socket, 'peer_unavailable', 'mac_connector is not connected yet');
        return;
      }
      sendJSON(targetPeer.socket, {
        type: 'bridge_frame',
        pairingId,
        fromRole: role,
        sourcePeerKey: socket.meta.peerKey,
        sourceDeviceId: socket.meta.deviceId,
        payload: bridgePayload,
      });
      return;
    }

    const targetPeerKey = String(payload.targetPeerKey || '').trim();
    const targetDeviceID = String(payload.targetDeviceId || payload.targetDeviceID || '').trim();
    let targetPeer = targetPeerKey ? state.peers.get(targetPeerKey) : null;
    if (!targetPeer && targetDeviceID) {
      targetPeer = state.peers.get(peerKeyFor('ios_client', targetDeviceID));
    }
    if (targetPeer) {
      sendJSON(targetPeer.socket, {
        type: 'bridge_frame',
        pairingId,
        fromRole: role,
        sourcePeerKey: socket.meta.peerKey,
        sourceDeviceId: socket.meta.deviceId,
        targetPeerKey: targetPeer.peerKey,
        targetDeviceId: targetPeer.deviceId,
        payload: bridgePayload,
      });
      return;
    }

    const iosPeers = peersForRole(state, 'ios_client');
    if (iosPeers.length === 0) {
      sendError(socket, 'peer_unavailable', 'ios_client is not connected yet');
      return;
    }
    for (const iosPeer of iosPeers) {
      sendJSON(iosPeer.socket, {
        type: 'bridge_frame',
        pairingId,
        fromRole: role,
        sourcePeerKey: socket.meta.peerKey,
        sourceDeviceId: socket.meta.deviceId,
        targetPeerKey: iosPeer.peerKey,
        targetDeviceId: iosPeer.deviceId,
        payload: bridgePayload,
      });
    }
    break;
  }
  case 'heartbeat':
  case 'pong':
    sendJSON(socket, {
      type: 'ack',
      message: `${type} accepted`,
      sentAt: new Date().toISOString(),
    });
    break;
  default:
    sendJSON(socket, {
      type: 'ack',
      message: type ? `ignored scaffold frame: ${type}` : 'ignored empty frame type',
      sentAt: new Date().toISOString(),
    });
    break;
  }
}

function startHeartbeatSweep() {
  if (pingTimer) return;
  pingTimer = setInterval(() => {
    const now = Date.now();
    for (const socket of sockets) {
      const lastSeenAt = socket.meta?.lastSeenAt || 0;
      if (lastSeenAt && now - lastSeenAt > HEARTBEAT_TIMEOUT_MS) {
        try {
          sendError(socket, 'heartbeat_timeout', 'relay timed out waiting for heartbeat');
          socket.close(4010, 'heartbeat timeout');
        } catch (_) {}
        continue;
      }
      sendJSON(socket, {
        type: 'ping',
        sentAt: new Date().toISOString(),
      });
    }
  }, PING_INTERVAL_MS);
}

const wss = new WebSocketServer({
  host: RELAY_HOST,
  port: RELAY_PORT,
  path: RELAY_PATH,
  perMessageDeflate: false,
});

wss.on('connection', (socket, request) => {
  sockets.add(socket);
  socket.meta = {
    remoteAddress: request.socket.remoteAddress,
    connectedAt: new Date().toISOString(),
    lastSeenAt: Date.now(),
  };
  log(`connection from ${socket.meta.remoteAddress || 'unknown'} on ${request.url || RELAY_PATH}`);

  sendJSON(socket, {
    type: 'hello',
    message: 'DexRelay internal scaffold relay ready',
    relayPath: RELAY_PATH,
    sentAt: new Date().toISOString(),
  });

  socket.on('message', (raw) => {
    const text = typeof raw === 'string' ? raw : raw.toString('utf8');
    handleFrame(socket, text);
  });

  socket.on('close', (code, reasonBuffer) => {
    const reason = reasonBuffer ? reasonBuffer.toString('utf8') : '';
    log(`connection closed (${code}${reason ? `: ${reason}` : ''})`);
    removeSocket(socket);
  });

  socket.on('error', (error) => {
    log(`socket error: ${error.message}`);
  });
});

wss.on('listening', () => {
  log(`listening on ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}`);
});

wss.on('error', (error) => {
  log(`server error: ${error.message}`);
});

startHeartbeatSweep();

function shutdown(signal) {
  log(`shutting down (${signal})`);
  if (pingTimer) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
  for (const socket of sockets) {
    try {
      socket.close(1001, 'relay shutdown');
    } catch (_) {}
  }
  wss.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
