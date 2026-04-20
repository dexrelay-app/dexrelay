# DexRelay

DexRelay is the public Mac-side CLI/bootstrap runtime for the DexRelay iPhone app.

This repository contains only the MIT-licensed DexRelay CLI, install/runtime scripts,
bridge/helper runtime files, setup guide assets, and related public bootstrap tooling.
The iOS app remains proprietary and is not included here.

## Install

Recommended:

```bash
brew install dexrelay-app/dexrelay/dexrelay && dexrelay install
```

Fallback:

```bash
curl -fsSL https://assets.dexrelay.app/install.sh | bash
```

## Runtime Defaults

- Runtime root: `~/Library/Application Support/DexRelay/runtime`
- Legacy runtime root: `~/src/CodexRelayBackendBootstrap`
- Admin workspace: `~/src/DexRelay Admin`
- Direct bridge port: `4615`
- Helper port: `4616`
- Relay server port: `4620`

## Key Commands

```bash
dexrelay install
dexrelay repair
dexrelay status
dexrelay pair
dexrelay relay-pair
dexrelay uninstall
dexrelay wake on
dexrelay wake off
dexrelay wake status
```

## Repository Scope

Public in this repository:

- `install.sh`
- `dexrelay`
- `bridge.js`
- `relay-server.js`
- `relay-connector.js`
- `helper.py`
- runtime helper scripts under the repo root
- setup guide assets

Not included:

- the proprietary DexRelay iOS app
- private internal docs
- private build/release credentials

