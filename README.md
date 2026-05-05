# Bootstrap Payload

This folder is the publishable DexRelay Mac payload.

It is the source of truth for:

- the public install script
- the public `dexrelay` CLI wrapper
- the public npm package
- the helper
- the bootstrap bridge runtime
- the optional relay runtime pieces
- the public setup guide and skill doc

## What this payload now represents

The current DexRelay product model is:

1. install DexRelay on the Mac
2. run `dexrelay pair`
3. scan the QR on the phone
4. use local Wi-Fi first
5. use Tailscale fallback when the device leaves Wi-Fi

So this payload is no longer just “install a bridge on `:4615`”.

Default direct transport is WebSocket on `:4615`. QUIC remains in the payload as an experimental opt-in path only, because enabling it requires a local TLS/private-key identity on macOS and can trigger a Keychain prompt.

It now owns:

- QR pairing
- helper health and setup state
- direct LAN-first bootstrap
- Tailscale fallback host bootstrap
- relay runtime scaffolding
- Mac-side self-heal behavior

## Public Cloudflare layout

```text
https://assets.dexrelay.app/install.sh
https://assets.dexrelay.app/bridge.js
https://assets.dexrelay.app/relay-server.js
https://assets.dexrelay.app/relay-connector.js
https://assets.dexrelay.app/package.json
https://assets.dexrelay.app/dexrelay
https://assets.dexrelay.app/helper.py
https://assets.dexrelay.app/create-mac-project.sh
https://assets.dexrelay.app/git-project-automation.sh
https://assets.dexrelay.app/governancectl.py
https://assets.dexrelay.app/services.registry.json
https://assets.dexrelay.app/servicectl.py
https://assets.dexrelay.app/rebuild-workspace-services.py
https://assets.dexrelay.app/codex-fast.py
https://assets.dexrelay.app/codex-health-daemon.py
https://assets.dexrelay.app/setup-guide.html
https://assets.dexrelay.app/dexrelay-skill.md
```

## Important runtime defaults

- runtime root: `~/Library/Application Support/DexRelay/runtime`
- admin workspace: `~/src/DexRelay Admin`
- direct bridge port: `4615`
- helper port: `4616`
- relay server port: `4620`

## Canonical user commands

- `dexrelay install`
- `dexrelay status`
- `dexrelay repair`
- `dexrelay pair`
- `dexrelay uninstall`
- `dexrelay wake on|off|status`

Advanced:

- `dexrelay relay-pair`

## User-facing happy path

Normal user flow should be:

1. run `curl -fsSL https://assets.dexrelay.app/install.sh | bash` on a clean Mac, or `npm i -g dexrelay` when npm already works
2. wait for DexRelay to bootstrap the Mac runtime automatically
3. on the Mac, run `dexrelay pair`
4. on the phone, scan the QR
5. start coding

Existing users upgrading from an older install should run `dexrelay repair` once so the runtime removes the old default QUIC gateway route and refreshes pairing metadata.

The direct installer is the first-run fallback for users without npm, with a broken npm global prefix, or with `/opt/homebrew/lib/node_modules` permission errors. The npm package cannot repair a missing npm binary because package scripts only run after npm has already started.

Tailscale is not supposed to be the first-run blocker for same-network onboarding anymore.

Instead:

- same Wi-Fi should work immediately
- Tailscale should keep DexRelay working away from Wi-Fi

## Reliability expectations

After install, the payload is expected to leave behind:

- launchd-managed DexRelay services
- helper
- watchdog
- keep-awake
- relay runtime support where configured

That means:

- `dexrelay status` is the canonical health view
- `dexrelay repair` is the canonical in-place fix
- `dexrelay install` is safe to rerun as an update or reinstall path
- `dexrelay install` should also migrate older project state from `.codex/` into `.dexrelay/`

## Release rule

If any thread changes:

- `install.sh`
- `dexrelay`
- `helper.py`
- `bridge.js`
- `relay-server.js`
- `relay-connector.js`
- `rebuild-workspace-services.py`
- public setup or skill docs

then the payload, docs, and installable skills must be released together.

The repo-owned Homebrew tap mirror is optional legacy infrastructure. It can be updated separately if needed, but it should not gate the standard DexRelay release.

See:

- [DEXRELAY_PUBLISHING.md](/Users/chetanankola/src/Codex%20iphone%20App/docs/DEXRELAY_PUBLISHING.md)
- [DEXRELAY_ONBOARDING_RUNTIME.md](/Users/chetanankola/src/Codex%20iphone%20App/docs/DEXRELAY_ONBOARDING_RUNTIME.md)
