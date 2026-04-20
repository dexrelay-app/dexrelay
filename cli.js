#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const cliPath = path.join(__dirname, "dexrelay");
const result = spawnSync(cliPath, process.argv.slice(2), {
  stdio: "inherit",
  env: process.env,
});

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 0);
