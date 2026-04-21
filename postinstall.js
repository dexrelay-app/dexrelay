#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

function log(message) {
  process.stdout.write(`[dexrelay postinstall] ${message}\n`);
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

if (shouldSkipAutoInstall()) {
  process.exit(0);
}

const installScript = path.join(__dirname, "install.sh");
const result = spawnSync("bash", [installScript], {
  cwd: __dirname,
  stdio: "inherit",
  env: {
    ...process.env,
    CODEX_RELAY_AUTO_INSTALL: "1",
    CODEX_RELAY_INSTALL_MODE: "npm-postinstall",
  },
});

if (result.error) {
  console.error(`[dexrelay postinstall] ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 0);
