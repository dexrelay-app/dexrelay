#!/usr/bin/env node

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

function createTerminalWriter() {
  try {
    const fd = fs.openSync("/dev/tty", "w");
    return {
      write(message) {
        fs.writeSync(fd, message);
      },
      close() {
        fs.closeSync(fd);
      },
    };
  } catch {
    return null;
  }
}

const terminalWriter = createTerminalWriter();

function write(message = "") {
  const line = `${message}\n`;
  if (terminalWriter) {
    terminalWriter.write(line);
    return;
  }
  process.stderr.write(line);
}

function log(message) {
  write(`[dexrelay postinstall] ${message}`);
}

function shouldSkipAutoInstall() {
  if (process.platform !== "darwin") {
    log("Skipping runtime bootstrap because DexRelay currently supports macOS only.");
    return true;
  }

  if (process.env.DEXRELAY_SKIP_POSTINSTALL === "1") {
    log("Skipping runtime bootstrap because DEXRELAY_SKIP_POSTINSTALL=1.");
    return true;
  }

  if (process.env.CI === "true") {
    log("Skipping runtime bootstrap in CI.");
    return true;
  }

  const isGlobal =
    process.env.npm_config_global === "true" ||
    process.env.npm_config_location === "global";
  if (!isGlobal) {
    log("Skipping automatic runtime bootstrap for a non-global npm install.");
    return true;
  }

  return false;
}

function formatDuration(ms) {
  const seconds = Math.max(1, Math.round(ms / 1000));
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = seconds % 60;
  return remainingSeconds === 0
    ? `${minutes}m`
    : `${minutes}m ${remainingSeconds}s`;
}

function renderHelpfulCommands() {
  return [
    "DexRelay is ready on this Mac.",
    "",
    "Useful commands:",
    "  dexrelay status   Check bridge, helper, and Tailscale health",
    "  dexrelay pair     Show the QR for the iPhone app",
    "  dexrelay repair   Repair the DexRelay runtime if services drift",
    "  dexrelay doctor   Show install paths and runtime metadata",
    "",
    "Next step: run `dexrelay pair` and scan it from the iPhone app.",
  ];
}

async function main() {
  if (shouldSkipAutoInstall()) {
    process.exit(0);
  }

  const installScript = path.join(__dirname, "install.sh");
  const startTime = Date.now();

  log("Installing the DexRelay Mac runtime. This usually takes 20-40 seconds.");
  log("Do not interrupt this step even if npm looks quiet for a moment.");

  const child = spawn("bash", [installScript], {
    cwd: __dirname,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      CODEX_RELAY_AUTO_INSTALL: "1",
      CODEX_RELAY_INSTALL_MODE: "npm-postinstall",
    },
  });

  let lastVisibleUpdateAt = Date.now();
  let heartbeatCount = 0;
  const heartbeatMessages = [
    "Still working: checking macOS prerequisites and network access.",
    "Still working: installing the DexRelay bridge and helper.",
    "Still working: starting background services and waiting for them to listen.",
    "Still working: verifying that your Mac connection path is healthy.",
  ];

  const heartbeat = setInterval(() => {
    const idleMs = Date.now() - lastVisibleUpdateAt;
    if (idleMs < 4000) {
      return;
    }
    const message = heartbeatMessages[Math.min(heartbeatCount, heartbeatMessages.length - 1)];
    heartbeatCount += 1;
    log(`${message} Elapsed ${formatDuration(Date.now() - startTime)}.`);
    lastVisibleUpdateAt = Date.now();
  }, 4000);

  const forwardLines = (stream, prefix) => {
    const rl = readline.createInterface({ input: stream });
    rl.on("line", (line) => {
      lastVisibleUpdateAt = Date.now();
      if (!line.trim()) {
        return;
      }
      write(`${prefix}${line}`);
    });
    return rl;
  };

  const stdoutReader = forwardLines(child.stdout, "");
  const stderrReader = forwardLines(child.stderr, "");

  const exitCode = await new Promise((resolve) => {
    child.on("error", (error) => {
      clearInterval(heartbeat);
      stdoutReader.close();
      stderrReader.close();
      log(`Failed to start install.sh: ${error.message}`);
      resolve(1);
    });
    child.on("close", (code) => {
      clearInterval(heartbeat);
      stdoutReader.close();
      stderrReader.close();
      resolve(code ?? 1);
    });
  });

  if (exitCode !== 0) {
    log(`DexRelay runtime install failed after ${formatDuration(Date.now() - startTime)}.`);
    process.exit(exitCode);
  }

  log(`DexRelay runtime install finished in ${formatDuration(Date.now() - startTime)}.`);
  write("");
  for (const line of renderHelpfulCommands()) {
    write(line);
  }
  terminalWriter?.close();
  process.exit(0);
}

main().catch((error) => {
  log(error instanceof Error ? error.message : String(error));
  terminalWriter?.close();
  process.exit(1);
});
