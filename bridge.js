const { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } = require('fs');
const { spawn } = require('child_process');
const readline = require('readline');
const os = require('os');
const path = require('path');
const WebSocket = require('ws');

const LISTEN_HOST = process.env.BRIDGE_HOST || '0.0.0.0';
const LISTEN_PORT = Number(process.env.BRIDGE_PORT || 4600);
const UPSTREAM_TRANSPORT = (process.env.UPSTREAM_TRANSPORT || 'stdio').toLowerCase();
const UPSTREAM_URL = process.env.UPSTREAM_URL || 'ws://127.0.0.1:4500';
const CODEX_BIN = process.env.CODEX_BIN || '/opt/homebrew/bin/codex';
const CLAUDE_BIN = process.env.CLAUDE_BIN
  || (existsSync(path.join(os.homedir(), '.local/bin/claude')) ? path.join(os.homedir(), '.local/bin/claude') : null)
  || (existsSync('/opt/homebrew/bin/claude') ? '/opt/homebrew/bin/claude' : 'claude');
const CODEX_UPSTREAM_CWD = process.env.CODEX_UPSTREAM_CWD || process.cwd();
const HISTORY_MAX_ITEMS = Number(process.env.HISTORY_MAX_ITEMS || 12);
const ITEM_TEXT_MAX_CHARS = Number(process.env.ITEM_TEXT_MAX_CHARS || 4000);
const MAX_MESSAGE_BYTES = Number(process.env.MAX_MESSAGE_BYTES || 900000);
const LOCAL_EXEC_OUTPUT_LIMIT = Number(process.env.LOCAL_EXEC_OUTPUT_LIMIT || 120000);
const LOCAL_READ_FILE_MAX_BYTES = Number(process.env.LOCAL_READ_FILE_MAX_BYTES || 25 * 1024 * 1024);
const LOCAL_UPLOAD_DIR = process.env.LOCAL_UPLOAD_DIR || path.join(os.tmpdir(), 'codex-remote-uploads');
const SESSION_HISTORY_CACHE_LIMIT = Number(process.env.SESSION_HISTORY_CACHE_LIMIT || 12);
const DETACHED_SESSION_MAX_MS = Number(process.env.DETACHED_SESSION_MAX_MS || 10 * 60 * 1000);
const DETACHED_IDLE_SHUTDOWN_MS = Number(process.env.DETACHED_IDLE_SHUTDOWN_MS || 15 * 1000);
const LIVE_SESSION_REPLAY_LIMIT = Number(process.env.LIVE_SESSION_REPLAY_LIMIT || 160);
const RECENT_TURN_REQUEST_GRACE_MS = Number(process.env.RECENT_TURN_REQUEST_GRACE_MS || 30 * 1000);
const RECENT_SESSION_ACTIVITY_GRACE_MS = Number(process.env.RECENT_SESSION_ACTIVITY_GRACE_MS || 90 * 1000);
const sessionHistoryCache = new Map();

const server = new WebSocket.Server({ host: LISTEN_HOST, port: LISTEN_PORT, perMessageDeflate: false });

function trimCommandOutput(value, limit = LOCAL_EXEC_OUTPUT_LIMIT) {
  if (typeof value !== 'string' || value.length <= limit) {
    return value;
  }
  return `[trimmed to last ${limit} chars]\n${value.slice(-limit)}`;
}

function sanitizeFileName(name = 'attachment') {
  return String(name)
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/^-+/, '')
    .slice(0, 120) || 'attachment';
}

function writeUploadedMedia(params = {}) {
  const fileName = sanitizeFileName(params.filename || 'attachment');
  const base64 = typeof params.dataBase64 === 'string' ? params.dataBase64 : '';
  if (!base64) {
    return { error: { code: -32602, message: 'local/uploadMedia requires dataBase64' } };
  }

  mkdirSync(LOCAL_UPLOAD_DIR, { recursive: true });
  const stampedName = `${Date.now()}-${fileName}`;
  const outPath = path.join(LOCAL_UPLOAD_DIR, stampedName);

  try {
    writeFileSync(outPath, Buffer.from(base64, 'base64'));
    return {
      result: {
        path: outPath,
        filename: fileName,
        mimeType: typeof params.mimeType === 'string' ? params.mimeType : '',
        size: Buffer.byteLength(base64, 'base64'),
      },
    };
  } catch (error) {
    return { error: { code: -32603, message: `Failed to write upload: ${error.message}` } };
  }
}

function readLocalFile(params = {}) {
  const rawPath = typeof params.path === 'string' ? params.path.trim() : '';
  const rawRoot = typeof params.rootPath === 'string' ? params.rootPath.trim() : '';
  const maxBytes = Number.isFinite(params.maxBytes)
    ? Math.max(1, Math.min(Number(params.maxBytes), LOCAL_READ_FILE_MAX_BYTES))
    : LOCAL_READ_FILE_MAX_BYTES;

  if (!rawPath) {
    return { error: { code: -32602, message: 'local/readFile requires params.path' } };
  }

  const resolvedPath = path.resolve(rawPath);
  if (rawRoot) {
    const resolvedRoot = path.resolve(rawRoot);
    const relative = path.relative(resolvedRoot, resolvedPath);
    if (relative.startsWith('..') || path.isAbsolute(relative)) {
      return { error: { code: -32602, message: 'Requested file is outside the project root' } };
    }
  }

  if (!existsSync(resolvedPath)) {
    return { error: { code: -32602, message: 'File not found' } };
  }

  let stats;
  try {
    stats = statSync(resolvedPath);
  } catch (error) {
    return { error: { code: -32603, message: `Could not stat file: ${error.message}` } };
  }

  if (!stats.isFile()) {
    return { error: { code: -32602, message: 'Requested path is not a file' } };
  }

  if (stats.size > maxBytes) {
    return {
      error: {
        code: -32602,
        message: `File is too large for mobile transfer (${stats.size} bytes; limit ${maxBytes} bytes)`,
      },
    };
  }

  try {
    const data = readFileSync(resolvedPath);
    return {
      result: {
        path: resolvedPath,
        filename: path.basename(resolvedPath),
        size: data.length,
        dataBase64: data.toString('base64'),
      },
    };
  } catch (error) {
    return { error: { code: -32603, message: `Could not read file: ${error.message}` } };
  }
}

function isSessionScaffoldText(text) {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  if (!trimmed) return true;
  return [
    '# AGENTS.md instructions',
    '<environment_context>',
    '<permissions instructions>',
    '<app-context>',
    '## Apps',
    '<collaboration_mode>',
    '<apps_instructions>',
    '<skills_instructions>',
    '<INSTRUCTIONS>',
  ].some((prefix) => trimmed.startsWith(prefix));
}

function isSessionImageMarkerText(text) {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  if (!trimmed) return false;
  return /^<image\b[^>]*>$/i.test(trimmed) || /^<\/image>$/i.test(trimmed);
}

function extractSessionMessageText(content, role) {
  if (!Array.isArray(content)) return null;
  const textParts = content
    .map((part) => {
      if (!part || typeof part !== 'object') return null;
      if (
        ['input_text', 'output_text', 'text'].includes(part.type) &&
        typeof part.text === 'string'
      ) {
        return part.text.trim();
      }
      return null;
    })
    .filter(Boolean);

  if (textParts.length === 0) return null;

  const relevantParts =
    role === 'user'
      ? textParts.filter((text) => !isSessionScaffoldText(text) && !isSessionImageMarkerText(text))
      : textParts;

  const chosenParts =
    relevantParts.length > 0
      ? relevantParts
      : role === 'user'
        ? textParts.slice(-1)
        : textParts;

  const joined = chosenParts
    .map((text) => truncateText(text))
    .join('\n\n')
    .trim();

  return joined || null;
}

function sessionTimestampToEpochSeconds(value) {
  if (typeof value !== 'string') return null;
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) return null;
  return Math.floor(parsed / 1000);
}

function pruneSessionHistoryCache() {
  while (sessionHistoryCache.size > SESSION_HISTORY_CACHE_LIMIT) {
    const oldestKey = sessionHistoryCache.keys().next().value;
    if (!oldestKey) break;
    sessionHistoryCache.delete(oldestKey);
  }
}

function cacheSessionHistory(resolvedPath, fileStats, messages) {
  sessionHistoryCache.set(resolvedPath, {
    mtimeMs: fileStats.mtimeMs,
    size: fileStats.size,
    messages,
  });
  pruneSessionHistoryCache();
  return messages;
}

function extractSessionAttachments(content) {
  if (!Array.isArray(content)) return [];

  const attachments = [];
  for (let index = 0; index < content.length; index += 1) {
    const part = content[index];
    if (!part || typeof part !== 'object') continue;

    const attachmentID =
      (typeof part.id === 'string' && part.id.trim()) ||
      `session-attachment-${index}`;

    if (['localImage', 'local_image'].includes(part.type) && typeof part.path === 'string' && part.path.trim()) {
      const localPath = part.path.trim();
      attachments.push({
        id: attachmentID,
        filename:
          (typeof part.filename === 'string' && part.filename.trim()) ||
          path.basename(localPath) ||
          'image',
        mimeType:
          (typeof part.mimeType === 'string' && part.mimeType.trim()) ||
          'image/*',
        kind: 'image',
        localPath,
      });
      continue;
    }

    const remoteURL =
      (typeof part.url === 'string' && part.url.trim()) ||
      (typeof part.image_url === 'string' && part.image_url.trim()) ||
      null;
    if (['image', 'input_image', 'output_image'].includes(part.type) && remoteURL) {
      const isDataURL = remoteURL.startsWith('data:');
      attachments.push({
        id: attachmentID,
        filename:
          (typeof part.filename === 'string' && part.filename.trim()) ||
          (!isDataURL ? path.basename(remoteURL) : '') ||
          'image',
        mimeType:
          (typeof part.mimeType === 'string' && part.mimeType.trim()) ||
          'image/*',
        kind: 'image',
        remoteURL,
      });
      continue;
    }

    if (['localFile', 'local_file', 'file'].includes(part.type)) {
      const localPath =
        (typeof part.path === 'string' && part.path.trim()) ||
        (typeof part.file_path === 'string' && part.file_path.trim()) ||
        null;
      const remoteFileURL =
        (typeof part.url === 'string' && part.url.trim()) ||
        null;
      if (!localPath && !remoteFileURL) continue;
      attachments.push({
        id: attachmentID,
        filename:
          (typeof part.filename === 'string' && part.filename.trim()) ||
          path.basename(localPath || remoteFileURL) ||
          'file',
        mimeType:
          (typeof part.mimeType === 'string' && part.mimeType.trim()) ||
          'application/octet-stream',
        kind: 'file',
        ...(localPath ? { localPath } : {}),
        ...(remoteFileURL ? { remoteURL: remoteFileURL } : {}),
      });
    }
  }

  return attachments;
}

function parseSessionMessages(fileText) {
  const messages = [];
  const lines = fileText.split('\n');
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) continue;

    let record;
    try {
      record = JSON.parse(line);
    } catch (_) {
      continue;
    }

    if (record?.type !== 'response_item') continue;
    const payload = record.payload;
    if (!payload || payload.type !== 'message') continue;
    const role = payload.role;
    if (!['user', 'assistant'].includes(role)) continue;

    const text = extractSessionMessageText(payload.content, role);
    const attachments = extractSessionAttachments(payload.content);
    if (!text && attachments.length === 0) continue;

    const itemID =
      (typeof payload.id === 'string' && payload.id.trim()) ||
      (typeof record.id === 'string' && record.id.trim()) ||
      `session-${index}`;

    messages.push({
      id: itemID,
      role,
      text: text || '',
      createdAt: sessionTimestampToEpochSeconds(record.timestamp),
      sortIndex: messages.length,
      attachments,
    });
  }

  return messages;
}

function readSessionHistoryPage(params = {}) {
  const rawPath = typeof params.sessionPath === 'string' ? params.sessionPath.trim() : '';
  const limit = Number.isFinite(params.limit)
    ? Math.max(1, Math.min(Number(params.limit), 100))
    : 24;
  const beforeCursor = Number.isFinite(params.beforeCursor)
    ? Math.max(0, Number(params.beforeCursor))
    : null;

  if (!rawPath) {
    return { error: { code: -32602, message: 'local/readSessionHistoryPage requires params.sessionPath' } };
  }

  const resolvedPath = path.resolve(rawPath);
  if (!existsSync(resolvedPath)) {
    return { error: { code: -32602, message: 'Session file not found' } };
  }

  let fileStats;
  try {
    fileStats = statSync(resolvedPath);
  } catch (error) {
    return { error: { code: -32603, message: `Could not stat session file: ${error.message}` } };
  }

  const cached = sessionHistoryCache.get(resolvedPath);
  let messages = null;
  if (cached && cached.mtimeMs === fileStats.mtimeMs && cached.size === fileStats.size) {
    messages = cached.messages;
    sessionHistoryCache.delete(resolvedPath);
    sessionHistoryCache.set(resolvedPath, cached);
  }

  if (!messages) {
    let fileText = '';
    try {
      fileText = readFileSync(resolvedPath, 'utf8');
    } catch (error) {
      return { error: { code: -32603, message: `Could not read session file: ${error.message}` } };
    }
    messages = cacheSessionHistory(resolvedPath, fileStats, parseSessionMessages(fileText));
  }

  const end = beforeCursor == null ? messages.length : Math.min(beforeCursor, messages.length);
  const start = Math.max(0, end - limit);
  const pageMessages = messages.slice(start, end);

  return {
    result: {
      sessionPath: resolvedPath,
      messages: pageMessages,
      nextCursor: start > 0 ? start : null,
      hasMore: start > 0,
      totalCount: messages.length,
    },
  };
}

function claudeProjectKeyForPath(cwd) {
  const resolved = path.resolve(typeof cwd === 'string' && cwd.trim() ? cwd.trim() : process.cwd());
  return resolved.replace(/[^A-Za-z0-9._-]/g, '-');
}

function parseClaudeJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch (_) {
    return null;
  }
}

function extractClaudeText(parsed, stdout) {
  if (!parsed || typeof parsed !== 'object') {
    return stdout.trim();
  }
  if (typeof parsed.result === 'string') return parsed.result.trim();
  if (typeof parsed.text === 'string') return parsed.text.trim();
  if (typeof parsed.message === 'string') return parsed.message.trim();
  if (Array.isArray(parsed.content)) {
    return parsed.content
      .map((part) => (typeof part?.text === 'string' ? part.text : ''))
      .filter(Boolean)
      .join('\n')
      .trim();
  }
  return stdout.trim();
}

function extractClaudeSessionID(parsed, stdout) {
  if (parsed && typeof parsed === 'object') {
    const direct = parsed.session_id || parsed.sessionId || parsed.sessionID;
    if (typeof direct === 'string' && direct.trim()) return direct.trim();
  }
  const match = stdout.match(/"session[_Iid]*"\s*:\s*"([^"]+)"/);
  return match?.[1] || null;
}

function runClaudeStatus() {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(CLAUDE_BIN, ['--version'], {
      cwd: process.cwd(),
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (error) => {
      resolve({ result: { installed: false, version: null, error: error.message } });
    });
    child.on('close', (code) => {
      const version = (stdout || stderr).trim();
      resolve({
        result: {
          installed: code === 0,
          version: version || null,
          claudeBin: CLAUDE_BIN,
        },
      });
    });
  });
}

function runClaudeModels() {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(CLAUDE_BIN, ['--help'], {
      cwd: process.cwd(),
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
    child.on('error', (error) => {
      resolve({ result: { models: [], supportsModelFlag: false, claudeBin: CLAUDE_BIN, error: error.message } });
    });
    child.on('close', (code) => {
      const helpText = `${stdout}\n${stderr}`;
      const supportsModelFlag = code === 0 && /--model\s+<model>/.test(helpText);
      resolve({
        result: {
          supportsModelFlag,
          claudeBin: CLAUDE_BIN,
          models: supportsModelFlag
            ? [
                { id: 'sonnet', displayName: 'Sonnet', model: 'sonnet' },
                { id: 'opus', displayName: 'Opus', model: 'opus' },
              ]
            : [],
        },
      });
    });
  });
}

function listClaudeSessions(params = {}) {
  const cwd = typeof params.cwd === 'string' && params.cwd.trim() ? params.cwd.trim() : process.cwd();
  const projectDir = path.join(os.homedir(), '.claude', 'projects', claudeProjectKeyForPath(cwd));
  if (!existsSync(projectDir)) {
    return { result: { sessions: [], projectDir } };
  }

  let entries = [];
  try {
    entries = readdirSync(projectDir)
      .filter((name) => name.endsWith('.jsonl'))
      .map((name) => {
        const filePath = path.join(projectDir, name);
        const stats = statSync(filePath);
        return {
          sessionId: name.replace(/\.jsonl$/, ''),
          sessionPath: filePath,
          updatedAt: stats.mtimeMs,
          size: stats.size,
        };
      })
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, 20);
  } catch (error) {
    return { error: { code: -32603, message: `Could not list Claude sessions: ${error.message}` } };
  }

  return { result: { sessions: entries, projectDir } };
}

function runClaudeSend(params = {}) {
  return new Promise((resolve) => {
    const prompt = typeof params.prompt === 'string' ? params.prompt : '';
    const cwd = typeof params.cwd === 'string' && params.cwd.trim() ? params.cwd.trim() : process.cwd();
    const sessionId = typeof params.sessionId === 'string' && params.sessionId.trim() ? params.sessionId.trim() : null;
    const timeoutMs = Number.isFinite(params.timeoutMs) ? Number(params.timeoutMs) : 600000;
    const inactivityTimeoutMs = Number.isFinite(params.inactivityTimeoutMs)
      ? Number(params.inactivityTimeoutMs)
      : 180000;
    const permissionMode = typeof params.permissionMode === 'string' && params.permissionMode.trim()
      ? params.permissionMode.trim()
      : 'default';
    const model = typeof params.model === 'string' && params.model.trim() ? params.model.trim() : null;

    if (!prompt.trim()) {
      resolve({ error: { code: -32602, message: 'local/claude/send requires params.prompt' } });
      return;
    }

    const args = [
      '-p',
      prompt,
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-mode',
      permissionMode,
    ];
    if (sessionId) {
      args.push('--resume', sessionId);
    }
    if (model) {
      args.push('--model', model);
    }
    if (params.dangerouslySkipPermissions === true) {
      args.push('--dangerously-skip-permissions');
    }

    let stdout = '';
    let stderr = '';
    let settled = false;
    let stdoutRemainder = '';
    let resultText = '';
    let streamSessionId = null;
    let lastProgressAt = Date.now();
    let inactivityTimedOut = false;
    const child = spawn(CLAUDE_BIN, args, {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      resolve(payload);
    };

    const timer = setTimeout(() => {
      stderr += `\nTimed out after ${timeoutMs}ms`;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 2000).unref();
    }, timeoutMs);

    const inactivityTimer = setInterval(() => {
      if (Date.now() - lastProgressAt < inactivityTimeoutMs) return;
      inactivityTimedOut = true;
      stderr += `\nNo Claude output for ${inactivityTimeoutMs}ms`;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 2000).unref();
    }, 5000);

    const handleClaudeStreamLine = (line) => {
      const parsed = parseClaudeJsonLine(line);
      if (!parsed || typeof parsed !== 'object') return;
      const directSessionId = parsed.session_id || parsed.sessionId || parsed.sessionID;
      if (typeof directSessionId === 'string' && directSessionId.trim()) {
        streamSessionId = directSessionId.trim();
      }
      if (parsed.type === 'result' && typeof parsed.result === 'string') {
        resultText = parsed.result.trim();
      }
    };

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      lastProgressAt = Date.now();
      stdout += text;
      if (stdout.length > LOCAL_EXEC_OUTPUT_LIMIT * 2) {
        stdout = stdout.slice(-LOCAL_EXEC_OUTPUT_LIMIT * 2);
      }
      stdoutRemainder += text;
      const lines = stdoutRemainder.split(/\r?\n/);
      stdoutRemainder = lines.pop() || '';
      for (const line of lines) {
        if (line.trim()) handleClaudeStreamLine(line.trim());
      }
    });
    child.stderr.on('data', (chunk) => {
      lastProgressAt = Date.now();
      stderr += chunk.toString();
      if (stderr.length > LOCAL_EXEC_OUTPUT_LIMIT * 2) {
        stderr = stderr.slice(-LOCAL_EXEC_OUTPUT_LIMIT * 2);
      }
    });
    child.on('error', (error) => {
      clearTimeout(timer);
      clearInterval(inactivityTimer);
      finish({
        result: {
          text: '',
          stdout: trimCommandOutput(stdout),
          stderr: trimCommandOutput(`${stderr}\n${error.message}`.trim()),
          exitCode: -1,
          claudeBin: CLAUDE_BIN,
        },
      });
    });
    child.on('close', (code, signal) => {
      clearTimeout(timer);
      clearInterval(inactivityTimer);
      if (stdoutRemainder.trim()) {
        handleClaudeStreamLine(stdoutRemainder.trim());
      }
      if (signal && code == null) {
        stderr = `${stderr}\nTerminated by signal ${signal}`.trim();
      }
      const parsed = parseClaudeJsonLine(stdout.trim().split('\n').filter(Boolean).pop() || stdout.trim());
      finish({
        result: {
          text: resultText || extractClaudeText(parsed, stdout),
          sessionId: streamSessionId || extractClaudeSessionID(parsed, stdout),
          stdout: trimCommandOutput(stdout),
          stderr: trimCommandOutput(stderr),
          exitCode: inactivityTimedOut ? -1 : (Number.isInteger(code) ? code : -1),
          claudeBin: CLAUDE_BIN,
        },
      });
    });
  });
}

function runLocalExec(params = {}) {
  return new Promise((resolve) => {
    const command = Array.isArray(params.command) ? params.command : null;
    const cwd = typeof params.cwd === 'string' && params.cwd.length > 0 ? params.cwd : process.cwd();
    const timeoutMs = Number.isFinite(params.timeoutMs) ? Number(params.timeoutMs) : 120000;

    if (!command || command.length === 0 || typeof command[0] !== 'string') {
      resolve({
        error: { code: -32602, message: 'local/exec requires params.command as a non-empty string array' },
      });
      return;
    }

    let stdout = '';
    let stderr = '';
    let settled = false;

    const child = spawn(command[0], command.slice(1), {
      cwd,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    const finish = (payload) => {
      if (settled) return;
      settled = true;
      resolve(payload);
    };

    const timer = setTimeout(() => {
      stderr += `\nTimed out after ${timeoutMs}ms`;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 2000).unref();
    }, timeoutMs);

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
      if (stdout.length > LOCAL_EXEC_OUTPUT_LIMIT * 2) {
        stdout = stdout.slice(-LOCAL_EXEC_OUTPUT_LIMIT * 2);
      }
    });

    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
      if (stderr.length > LOCAL_EXEC_OUTPUT_LIMIT * 2) {
        stderr = stderr.slice(-LOCAL_EXEC_OUTPUT_LIMIT * 2);
      }
    });

    child.on('error', (error) => {
      clearTimeout(timer);
      finish({
        result: {
          stdout: trimCommandOutput(stdout),
          stderr: trimCommandOutput(`${stderr}\n${error.message}`.trim()),
          exitCode: -1,
        },
      });
    });

    child.on('close', (code, signal) => {
      clearTimeout(timer);
      if (signal && code == null) {
        stderr = `${stderr}\nTerminated by signal ${signal}`.trim();
      }
      finish({
        result: {
          stdout: trimCommandOutput(stdout),
          stderr: trimCommandOutput(stderr),
          exitCode: Number.isInteger(code) ? code : -1,
        },
      });
    });
  });
}

async function handleLocalRPC(client, incoming, cid, localContext = {}) {
  if (!incoming || typeof incoming !== 'object' || typeof incoming.method !== 'string') {
    return false;
  }

  if (![
    'local/exec',
    'local/uploadMedia',
    'local/readFile',
    'local/readSessionHistoryPage',
    'local/listLiveSessions',
    'local/attachLiveSession',
    'local/claude/status',
    'local/claude/models',
    'local/claude/listSessions',
    'local/claude/send',
  ].includes(incoming.method)) {
    return false;
  }

  if (!Number.isInteger(incoming.id)) {
    return true;
  }

  const response =
    incoming.method === 'local/uploadMedia'
      ? writeUploadedMedia(incoming.params)
      : incoming.method === 'local/readFile'
        ? readLocalFile(incoming.params)
        : incoming.method === 'local/readSessionHistoryPage'
          ? readSessionHistoryPage(incoming.params)
          : incoming.method === 'local/listLiveSessions'
            ? { result: { sessions: typeof localContext.listLiveSessions === 'function' ? localContext.listLiveSessions() : [] } }
            : incoming.method === 'local/attachLiveSession'
              ? await (typeof localContext.attachLiveSession === 'function'
                ? localContext.attachLiveSession(incoming.params || {})
                : { error: { code: -32603, message: 'Live session attach is unavailable' } })
              : incoming.method === 'local/claude/status'
                ? await runClaudeStatus()
                : incoming.method === 'local/claude/models'
                  ? await runClaudeModels()
                  : incoming.method === 'local/claude/listSessions'
                    ? listClaudeSessions(incoming.params || {})
                    : incoming.method === 'local/claude/send'
                      ? await runClaudeSend(incoming.params || {})
        : await runLocalExec(incoming.params);
  if (client.readyState === WebSocket.OPEN) {
    const payload = {
      jsonrpc: '2.0',
      id: incoming.id,
      ...(response.error ? { error: response.error } : { result: response.result }),
    };
    client.send(
      [
        'local/readFile',
        'local/readSessionHistoryPage',
        'local/listLiveSessions',
        'local/attachLiveSession',
        'local/claude/status',
        'local/claude/models',
        'local/claude/listSessions',
        'local/claude/send',
      ].includes(incoming.method)
        ? JSON.stringify(payload)
        : serializeForMobile(payload),
      { binary: false }
    );
  }
  console.log(`[${cid}] handled local method ${incoming.method}`);
  return true;
}

function truncateText(value, maxChars = ITEM_TEXT_MAX_CHARS) {
  if (typeof value !== 'string') return value;
  if (value.length <= maxChars) return value;
  return `${value.slice(0, maxChars)}\n\n[truncated for mobile]`;
}

function sanitizeItem(item) {
  if (!item || typeof item !== 'object') return null;
  const type = item.type;
  if (!['userMessage', 'agentMessage', 'plan', 'reasoning'].includes(type)) {
    return null;
  }

  if (type === 'userMessage' && Array.isArray(item.content)) {
    const content = item.content.map((part) => {
      if (!part || typeof part !== 'object') return part;
      if (typeof part.text === 'string') {
        return { type: part.type, text: truncateText(part.text) };
      }
      if (part.type === 'localImage' && typeof part.path === 'string') {
        return { type: 'localImage', path: part.path };
      }
      const imageURL =
        (typeof part.url === 'string' && part.url.trim()) ||
        (typeof part.image_url === 'string' && part.image_url.trim()) ||
        null;
      if (['image', 'input_image', 'output_image'].includes(part.type) && imageURL) {
        return { type: part.type, url: imageURL };
      }
      return null;
    }).filter(Boolean);
    return {
      id: item.id,
      type,
      createdAt: item.createdAt,
      content,
    };
  }

  if (type === 'reasoning') {
    return {
      id: item.id,
      type,
      createdAt: item.createdAt,
      summary: typeof item.summary === 'string' ? truncateText(item.summary) : undefined,
      content: typeof item.content === 'string' ? truncateText(item.content) : undefined,
    };
  }

  return {
    id: item.id,
    type,
    createdAt: item.createdAt,
    text: typeof item.text === 'string' ? truncateText(item.text) : undefined,
  };
}

function reduceThreadTurnsForMobile(turns) {
  if (!Array.isArray(turns) || turns.length === 0) return [];

  const reducedTurnsReversed = [];
  let collected = 0;

  for (let i = turns.length - 1; i >= 0; i -= 1) {
    if (collected >= HISTORY_MAX_ITEMS) break;
    const turn = turns[i];
    const items = Array.isArray(turn?.items) ? turn.items : [];
    const sanitized = items.map(sanitizeItem).filter(Boolean);
    if (sanitized.length === 0) continue;

    const remaining = HISTORY_MAX_ITEMS - collected;
    const tail = sanitized.slice(-remaining);
    collected += tail.length;
    reducedTurnsReversed.push({ ...turn, items: tail });
  }

  return reducedTurnsReversed.reverse();
}

function sanitizeTurn(turn) {
  if (!turn || typeof turn !== 'object') return turn;
  const items = Array.isArray(turn.items) ? turn.items : [];
  const sanitized = items.map(sanitizeItem).filter(Boolean);
  return {
    id: turn.id ?? turn.turnId ?? turn.turn_id,
    status: turn.status,
    createdAt: turn.createdAt,
    updatedAt: turn.updatedAt,
    kind: turn.kind,
    items: sanitized.slice(-HISTORY_MAX_ITEMS),
  };
}

function sanitizeThread(thread) {
  if (!thread || typeof thread !== 'object') return thread;
  const next = { ...thread };
  if (Array.isArray(thread.turns)) {
    next.turns = reduceThreadTurnsForMobile(thread.turns);
    next.mobileHistoryTrimmed = true;
  }
  return next;
}

function threadSkeletonForMobile(thread) {
  if (!thread || typeof thread !== 'object') return { turns: [], mobileHistoryTrimmed: true };
  return {
    id: thread.id,
    title: thread.title,
    status: thread.status,
    cwd: thread.cwd,
    path: thread.path,
    updatedAt: thread.updatedAt,
    updated_at: thread.updated_at,
    explicitName: thread.explicitName,
    turns: [],
    mobileHistoryTrimmed: true,
    mobileHistoryUnavailable: 'payload_too_large',
  };
}

function sanitizePayloadForMobile(payload) {
  if (!payload || typeof payload !== 'object') return payload;

  const next = { ...payload };

  if (next.result && typeof next.result === 'object') {
    next.result = { ...next.result };
    if (next.result.thread) {
      next.result.thread = sanitizeThread(next.result.thread);
    }
    if (next.result.turn && typeof next.result.turn === 'object') {
      next.result.turn = sanitizeTurn(next.result.turn);
    }
    if (Array.isArray(next.result.turns)) {
      next.result.turns = reduceThreadTurnsForMobile(next.result.turns);
    }
  }

  if (next.params && typeof next.params === 'object') {
    next.params = { ...next.params };
    if (next.params.thread) {
      next.params.thread = sanitizeThread(next.params.thread);
    }
    if (next.params.turn && typeof next.params.turn === 'object') {
      next.params.turn = sanitizeTurn(next.params.turn);
    }
    if (Array.isArray(next.params.turns)) {
      next.params.turns = reduceThreadTurnsForMobile(next.params.turns);
    }
    if (Array.isArray(next.params.items)) {
      next.params.items = next.params.items.map(sanitizeItem).filter(Boolean).slice(-HISTORY_MAX_ITEMS);
    }
  }

  return next;
}

function serializeForMobile(payload) {
  let text = JSON.stringify(sanitizePayloadForMobile(payload));
  if (Buffer.byteLength(text, 'utf8') <= MAX_MESSAGE_BYTES) {
    return text;
  }

  const moreAggressive = JSON.parse(text);
  if (moreAggressive?.result?.thread?.turns) {
    moreAggressive.result.thread.turns = reduceThreadTurnsForMobile(
      moreAggressive.result.thread.turns.slice(-6).map((turn) => ({
        ...turn,
        items: (Array.isArray(turn.items) ? turn.items : [])
          .map((item) => sanitizeItem(item))
          .filter(Boolean)
          .slice(-6)
          .map((item) => {
            const next = { ...item };
            if (typeof next.text === 'string') next.text = truncateText(next.text, 1200);
            if (typeof next.summary === 'string') next.summary = truncateText(next.summary, 1200);
            if (typeof next.content === 'string') next.content = truncateText(next.content, 1200);
            if (Array.isArray(next.content)) {
              next.content = next.content.map((part) =>
                typeof part?.text === 'string' ? { ...part, text: truncateText(part.text, 1200) } : part
              );
            }
            return next;
          }),
      })));
  }
  if (moreAggressive?.params?.thread?.turns) {
    moreAggressive.params.thread.turns = reduceThreadTurnsForMobile(
      moreAggressive.params.thread.turns.slice(-6)
    );
  }
  if (Array.isArray(moreAggressive?.params?.items)) {
    moreAggressive.params.items = moreAggressive.params.items
      .map((item) => sanitizeItem(item))
      .filter(Boolean)
      .slice(-6);
  }
  text = JSON.stringify(moreAggressive);

  if (Buffer.byteLength(text, 'utf8') > MAX_MESSAGE_BYTES) {
    const compactResult = moreAggressive.result && typeof moreAggressive.result === 'object'
      ? {
          ...moreAggressive.result,
          thread: moreAggressive.result.thread ? threadSkeletonForMobile(moreAggressive.result.thread) : undefined,
          turns: Array.isArray(moreAggressive.result.turns) ? [] : moreAggressive.result.turns,
          mobilePayloadTrimmed: true,
        }
      : moreAggressive.result;

    const compactParams = moreAggressive.params && typeof moreAggressive.params === 'object'
      ? {
          ...moreAggressive.params,
          thread: moreAggressive.params.thread ? threadSkeletonForMobile(moreAggressive.params.thread) : undefined,
          turns: Array.isArray(moreAggressive.params.turns) ? [] : moreAggressive.params.turns,
          items: Array.isArray(moreAggressive.params.items) ? [] : moreAggressive.params.items,
          mobilePayloadTrimmed: true,
        }
      : moreAggressive.params;

    return JSON.stringify({
      method: moreAggressive.method,
      id: moreAggressive.id,
      result: compactResult,
      params: compactParams,
    });
  }

  return text;
}

function summarizeRPCForLog(message) {
  if (!message || typeof message !== 'object') return 'unknown';
  const method = typeof message.method === 'string' ? message.method : 'response';
  const params = message.params && typeof message.params === 'object' ? message.params : null;
  const result = message.result && typeof message.result === 'object' ? message.result : null;
  const threadID = extractThreadIDFromMessage(message);
  const turnID =
    (typeof params?.expectedTurnId === 'string' && params.expectedTurnId) ||
    (typeof params?.turnId === 'string' && params.turnId) ||
    (typeof result?.turnId === 'string' && result.turnId) ||
    (typeof result?.turn_id === 'string' && result.turn_id) ||
    (typeof result?.turn?.id === 'string' && result.turn.id) ||
    null;
  const idPart = Number.isInteger(message.id) ? ` id=${message.id}` : '';
  const threadPart = threadID ? ` thread=${threadID}` : '';
  const turnPart = turnID ? ` turn=${turnID}` : '';
  return `${method}${idPart}${threadPart}${turnPart}`;
}

function extractThreadIDFromMessage(message) {
  if (!message || typeof message !== 'object') return null;

  const params = message.params && typeof message.params === 'object' ? message.params : null;
  const result = message.result && typeof message.result === 'object' ? message.result : null;
  const candidates = [
    params?.threadId,
    params?.thread?.id,
    params?.turn?.threadId,
    params?.turn?.thread_id,
    result?.threadId,
    result?.thread?.id,
    result?.turn?.threadId,
    result?.turn?.thread_id,
  ];

  const match = candidates.find((value) => typeof value === 'string' && value.trim());
  return match ? match.trim() : null;
}

function threadStatusIsActive(status) {
  if (!status) return false;
  if (typeof status === 'string') {
    return ['active', 'inprogress', 'running'].includes(status.toLowerCase());
  }
  if (typeof status === 'object') {
    if (typeof status.type === 'string') {
      return ['active', 'inprogress', 'running'].includes(status.type.toLowerCase());
    }
    if (Array.isArray(status.activeFlags) && status.activeFlags.length > 0) {
      return true;
    }
  }
  return false;
}

function updateActiveThreadsFromMessage(message, activeThreadIDs) {
  if (!message || typeof message !== 'object') return;

  const method = typeof message.method === 'string' ? message.method : null;
  const threadID = extractThreadIDFromMessage(message);

  if (method === 'turn/started') {
    if (threadID) activeThreadIDs.add(threadID);
    return;
  }

  if (['turn/completed', 'turn/failed', 'turn/interrupted', 'turn/cancelled'].includes(method)) {
    if (threadID) activeThreadIDs.delete(threadID);
    return;
  }

  if (method === 'thread/status/changed') {
    const status = message.params?.thread?.status ?? message.params?.status ?? message.result?.thread?.status;
    if (!threadID) return;
    if (threadStatusIsActive(status)) {
      activeThreadIDs.add(threadID);
    } else {
      activeThreadIDs.delete(threadID);
    }
  }
}

const bridgeSessions = new Map();
let nextBridgeSessionID = 1;

function createBridgeSession() {
  const sessionID = `live_${Date.now().toString(36)}_${nextBridgeSessionID++}`;
  const upstream =
    UPSTREAM_TRANSPORT === 'websocket'
      ? new WebSocket(UPSTREAM_URL, { perMessageDeflate: false })
      : spawn(CODEX_BIN, ['app-server'], {
          cwd: CODEX_UPSTREAM_CWD,
          env: process.env,
          stdio: ['pipe', 'pipe', 'pipe'],
        });

  const session = {
    id: sessionID,
    upstream,
    upstreamReady: false,
    pending: [],
    readHistoryRequestIDs: new Set(),
    pendingTurnRequestThreadIDs: new Map(),
    activeThreadIDs: new Set(),
    seenThreadIDs: new Set(),
    recentFrames: [],
    attachedClient: null,
    attachedClientID: null,
    detachedHeadless: false,
    closed: false,
    detachedShutdownTimer: null,
    detachedMaxTimer: null,
    createdAt: Date.now(),
    lastEventAt: Date.now(),
    lastTurnRequestAt: 0,
  };

  bridgeSessions.set(sessionID, session);

  const logPrefix = () => `[session ${session.id}${session.attachedClientID ? ` client ${session.attachedClientID}` : ''}]`;

  const clearDetachedTimers = () => {
    if (session.detachedShutdownTimer) {
      clearTimeout(session.detachedShutdownTimer);
      session.detachedShutdownTimer = null;
    }
    if (session.detachedMaxTimer) {
      clearTimeout(session.detachedMaxTimer);
      session.detachedMaxTimer = null;
    }
  };

  const recordFrame = (text, isBinary = false) => {
    if (isBinary || typeof text !== 'string' || !text.length) return;
    session.recentFrames.push(text);
    if (session.recentFrames.length > LIVE_SESSION_REPLAY_LIMIT) {
      session.recentFrames.splice(0, session.recentFrames.length - LIVE_SESSION_REPLAY_LIMIT);
    }
  };

  const deliverFrame = (text, isBinary = false) => {
    if (!session.attachedClient || session.attachedClient.readyState !== WebSocket.OPEN) return;
    session.attachedClient.send(isBinary ? text : text, { binary: isBinary });
  };

  const close = (why) => {
    if (session.closed) return;
    session.closed = true;
    clearDetachedTimers();
    bridgeSessions.delete(session.id);
    if (why) console.log(`${logPrefix()} closing: ${why}`);
    if (session.attachedClient && [WebSocket.OPEN, WebSocket.CONNECTING].includes(session.attachedClient.readyState)) {
      try { session.attachedClient.close(); } catch (_) {}
    }
    if (UPSTREAM_TRANSPORT === 'websocket') {
      if ([WebSocket.OPEN, WebSocket.CONNECTING].includes(session.upstream.readyState)) {
        try { session.upstream.close(); } catch (_) {}
      }
    } else {
      try { session.upstream.stdin.end(); } catch (_) {}
      try { session.upstream.kill('SIGTERM'); } catch (_) {}
    }
  };

  const scheduleDetachedShutdown = (delayMs, reason) => {
    if (session.closed) return;
    if (session.detachedShutdownTimer) {
      clearTimeout(session.detachedShutdownTimer);
    }
    session.detachedShutdownTimer = setTimeout(() => {
      session.detachedShutdownTimer = null;
      close(reason);
    }, delayMs);
    session.detachedShutdownTimer.unref?.();
  };

  const refreshDetachedLifetime = (reason) => {
    if (!session.detachedHeadless || session.closed) return;

    if (session.activeThreadIDs.size > 0) {
      if (!session.detachedMaxTimer) {
        session.detachedMaxTimer = setTimeout(() => {
          session.detachedMaxTimer = null;
          close('detached max lifetime reached');
        }, DETACHED_SESSION_MAX_MS);
        session.detachedMaxTimer.unref?.();
      }
      if (session.detachedShutdownTimer) {
        clearTimeout(session.detachedShutdownTimer);
        session.detachedShutdownTimer = null;
      }
      return;
    }

    scheduleDetachedShutdown(DETACHED_IDLE_SHUTDOWN_MS, reason);
  };

  const hasReconnectableWork = () => {
    if (session.activeThreadIDs.size > 0) return true;
    if (session.pendingTurnRequestThreadIDs.size > 0) return true;
    if (
      session.lastTurnRequestAt > 0 &&
      Date.now() - session.lastTurnRequestAt <= RECENT_TURN_REQUEST_GRACE_MS &&
      session.seenThreadIDs.size > 0
    ) {
      return true;
    }
    if (
      session.seenThreadIDs.size > 0 &&
      Date.now() - Math.max(session.lastEventAt, session.lastTurnRequestAt, session.createdAt)
        <= RECENT_SESSION_ACTIVITY_GRACE_MS
    ) {
      return true;
    }
    return false;
  };

  const flush = () => {
    if (!session.upstreamReady) return;
    while (
      session.pending.length > 0 &&
      (UPSTREAM_TRANSPORT === 'websocket'
        ? session.upstream.readyState === WebSocket.OPEN
        : session.upstream.stdin && !session.upstream.stdin.destroyed)
    ) {
      const { data, isBinary } = session.pending.shift();
      if (UPSTREAM_TRANSPORT === 'websocket') {
        session.upstream.send(data, { binary: isBinary });
      } else if (!isBinary) {
        session.upstream.stdin.write(`${data.toString()}\n`);
      }
    }
  };

  const attachClient = (client, cid, replayRecent = true) => {
    if (
      session.attachedClient &&
      session.attachedClient !== client
    ) {
      try { session.attachedClient.close(); } catch (_) {}
    }
    session.attachedClient = client;
    session.attachedClientID = cid;
    session.detachedHeadless = false;
    clearDetachedTimers();
    if (replayRecent && client.readyState === WebSocket.OPEN) {
      for (const frame of session.recentFrames) {
        client.send(frame, { binary: false });
      }
    }
    return true;
  };

  const handleClientMessage = async (client, cid, data, isBinary) => {
    if (!isBinary) {
      try {
        const incoming = JSON.parse(data.toString());
        console.log(`${logPrefix()} client rpc ${summarizeRPCForLog(incoming)}`);
        if (
          Number.isInteger(incoming?.id) &&
          ['turn/start', 'turn/steer'].includes(incoming.method) &&
          typeof incoming.params?.threadId === 'string' &&
          incoming.params.threadId.trim()
        ) {
          const threadID = incoming.params.threadId.trim();
          session.pendingTurnRequestThreadIDs.set(incoming.id, threadID);
          session.activeThreadIDs.add(threadID);
          session.seenThreadIDs.add(threadID);
          session.lastTurnRequestAt = Date.now();
          console.log(`${logPrefix()} queued ${incoming.method} for thread ${threadID}`);
        }
        if (
          incoming &&
          incoming.method === 'thread/read' &&
          incoming.params &&
          incoming.params.includeTurns === true &&
          Number.isInteger(incoming.id)
        ) {
          session.readHistoryRequestIDs.add(incoming.id);
        }
      } catch (_) {}
    }

    if (
      session.upstreamReady &&
      (UPSTREAM_TRANSPORT === 'websocket'
        ? session.upstream.readyState === WebSocket.OPEN
        : session.upstream.stdin && !session.upstream.stdin.destroyed)
    ) {
      if (UPSTREAM_TRANSPORT === 'websocket') {
        session.upstream.send(data, { binary: isBinary });
      } else if (!isBinary) {
        try {
          session.upstream.stdin.write(`${data.toString()}\n`);
        } catch (error) {
          close(`upstream stdin write failed: ${error.message}`);
        }
      }
    } else {
      session.pending.push({ data, isBinary });
    }
  };

    const processIncomingPayload = (payload) => {
    console.log(`${logPrefix()} upstream rpc ${summarizeRPCForLog(payload)}`);
    if (Number.isInteger(payload?.id) && session.pendingTurnRequestThreadIDs.has(payload.id)) {
      const pendingThreadID = session.pendingTurnRequestThreadIDs.get(payload.id);
      session.pendingTurnRequestThreadIDs.delete(payload.id);
      if (payload.error && pendingThreadID) {
        session.activeThreadIDs.delete(pendingThreadID);
      }
    }
    const threadID = extractThreadIDFromMessage(payload);
    if (threadID) {
      session.seenThreadIDs.add(threadID);
    }
    updateActiveThreadsFromMessage(payload, session.activeThreadIDs);
    session.lastEventAt = Date.now();
    refreshDetachedLifetime('detached session became idle');
    if (Number.isInteger(payload?.id) && session.readHistoryRequestIDs.has(payload.id)) {
      session.readHistoryRequestIDs.delete(payload.id);
    }
  };

  if (UPSTREAM_TRANSPORT === 'websocket') {
    upstream.on('open', () => {
      session.upstreamReady = true;
      console.log(`${logPrefix()} upstream open`);
      flush();
    });

    upstream.on('message', (data, isBinary) => {
      if (isBinary) {
        deliverFrame(data, true);
        return;
      }

      let text = data.toString();
      try {
        const payload = JSON.parse(text);
        processIncomingPayload(payload);
        text = serializeForMobile(payload);
      } catch (_) {}
      recordFrame(text, false);
      deliverFrame(text, false);
    });

    upstream.on('close', () => close('upstream closed'));
    upstream.on('error', (err) => close(`upstream error: ${err.message}`));
  } else {
    session.upstreamReady = true;
    console.log(`${logPrefix()} upstream open (stdio)`);
    flush();

    const rl = readline.createInterface({ input: upstream.stdout });
    rl.on('line', (line) => {
      let text = line;
      try {
        const payload = JSON.parse(line);
        processIncomingPayload(payload);
        text = serializeForMobile(payload);
      } catch (_) {}
      recordFrame(text, false);
      deliverFrame(text, false);
    });

    upstream.stderr.on('data', (chunk) => {
      const msg = chunk.toString().trim();
      if (msg) {
        console.log(`${logPrefix()} upstream stderr: ${msg}`);
      }
    });

    upstream.on('exit', (code, signal) => {
      close(`upstream exited code=${code ?? 'null'} signal=${signal ?? 'null'}`);
    });
    upstream.on('error', (err) => close(`upstream process error: ${err.message}`));
  }

  session.attachClient = attachClient;
  session.handleClientMessage = handleClientMessage;
  session.handleClientDisconnect = (client, reason) => {
    if (session.closed) return;
    if (session.attachedClient === client) {
      session.attachedClient = null;
      session.attachedClientID = null;
    }
    if (UPSTREAM_TRANSPORT === 'stdio' && hasReconnectableWork()) {
      session.detachedHeadless = true;
      console.log(
        `${logPrefix()} ${reason}; keeping upstream alive ` +
        `(active=${session.activeThreadIDs.size} pending=${session.pendingTurnRequestThreadIDs.size} seen=${session.seenThreadIDs.size})`
      );
      refreshDetachedLifetime('detached session idle after active turn');
      return;
    }
    close(reason);
  };
  session.close = close;

  return session;
}

function listLiveSessions() {
  return Array.from(bridgeSessions.values())
    .filter((session) => !session.closed && session.detachedHeadless)
    .sort((left, right) => right.lastEventAt - left.lastEventAt)
    .map((session) => ({
      sessionId: session.id,
      activeThreadIDs: Array.from(session.activeThreadIDs),
      threadIDs: Array.from(session.seenThreadIDs),
      detached: session.detachedHeadless,
      lastEventAt: session.lastEventAt,
      createdAt: session.createdAt,
    }));
}

function findLiveSessionForThreadIDs(threadIDs) {
  const normalized = (Array.isArray(threadIDs) ? threadIDs : [])
    .filter((value) => typeof value === 'string' && value.trim())
    .map((value) => value.trim());
  if (normalized.length === 0) return null;

  return Array.from(bridgeSessions.values())
    .filter((session) => {
      if (session.closed) return false;
      const pool = new Set([...session.activeThreadIDs, ...session.seenThreadIDs]);
      return normalized.some((threadID) => pool.has(threadID));
    })
    .sort((left, right) => right.lastEventAt - left.lastEventAt)[0] ?? null;
}

server.on('listening', () => {
  const upstreamTarget =
    UPSTREAM_TRANSPORT === 'websocket'
      ? UPSTREAM_URL
      : `${CODEX_BIN} app-server (stdio)`;
  console.log(`bridge listening on ws://${LISTEN_HOST}:${LISTEN_PORT} -> ${upstreamTarget}`);
  console.log(`mobile history window: last ${HISTORY_MAX_ITEMS} message items`);
});

server.on('connection', (client, req) => {
  const cid = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
  console.log(`[${cid}] client connected`);
  let currentSession = null;

  const localContext = {
    listLiveSessions,
    attachLiveSession: async (params = {}) => {
      const threadIDs = Array.isArray(params.threadIds) ? params.threadIds : [];
      const session = findLiveSessionForThreadIDs(threadIDs);
      if (!session) {
        return { result: { attached: false, sessions: listLiveSessions() } };
      }
      if (currentSession && currentSession !== session) {
        currentSession.handleClientDisconnect(client, 'client switched live session');
      }
      session.attachClient(client, cid, true);
      currentSession = session;
      return {
        result: {
          attached: true,
          sessionId: session.id,
          threadIds: Array.from(session.seenThreadIDs),
          activeThreadIDs: Array.from(session.activeThreadIDs),
        },
      };
    },
  };

  client.on('message', async (data, isBinary) => {
    if (!isBinary) {
      try {
        const incoming = JSON.parse(data.toString());
        if (await handleLocalRPC(client, incoming, cid, localContext)) {
          return;
        }
      } catch (_) {}
    }

    if (!currentSession) {
      currentSession = createBridgeSession();
      currentSession.attachClient(client, cid, false);
    }
    await currentSession.handleClientMessage(client, cid, data, isBinary);
  });

  client.on('close', () => {
    if (currentSession) {
      currentSession.handleClientDisconnect(client, 'client closed');
    }
  });

  client.on('error', (err) => {
    if (currentSession) {
      currentSession.handleClientDisconnect(client, `client error: ${err.message}`);
    }
  });
});

server.on('error', (err) => {
  console.error('bridge error:', err.message);
  process.exit(1);
});
