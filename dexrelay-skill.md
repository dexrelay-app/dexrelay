# DexRelay Skill

Use the DexRelay skills when you want Codex to install, pair, repair, or normalize the DexRelay Mac runtime for the iPhone app.

This page is the public reference. The canonical install target for Codex is the GitHub `dexrelay-setup` skill path.

## Recommended skill

- `dexrelay-setup`

## Install alias

- `dexrelay-install`

## Repair-oriented local skill

- `dexrelay-repair`

## Canonical install targets

- `https://github.com/dexrelay-app/dexrelay-skills/tree/main/dexrelay-setup`
- `https://github.com/dexrelay-app/dexrelay-skills/tree/main/dexrelay-install`

## Install with Codex

1. use the `skill-installer` skill
2. install `https://github.com/dexrelay-app/dexrelay-skills/tree/main/dexrelay-setup`
3. use `dexrelay-install` only if you specifically want the install alias

## What the skill should cover

The DexRelay skill flow should handle the complete operator path:

1. install DexRelay on the Mac
2. run `dexrelay pair`
3. pair the phone through the QR flow
4. prefer local Wi-Fi first
5. use Tailscale when leaving Wi-Fi
6. use `dexrelay status` and `dexrelay repair` when something breaks
7. refresh project governance when DexRelay is healthy but actions are stale

## Minimum skill coverage

`dexrelay-setup` should be able to help with:

- Homebrew install and `dexrelay install`
- helper, bridge, watchdog, and keep-awake verification
- `dexrelay pair`
- `dexrelay status`
- `dexrelay repair`
- `dexrelay uninstall`
- `dexrelay wake on`
- `dexrelay wake off`
- `dexrelay wake status`
- Tailscale install and same-account guidance
- project governance refresh if DexRelay is healthy but project actions are stale

## Repair-oriented edge cases

When setup is already present but broken, the skill should help identify:

- broken Mac runtime
- helper not reachable
- relay or bridge down
- Tailscale missing or disconnected
- phone connects on Wi-Fi but not away from home
- stale setup states that need a clear repair order

## Preferred install command

```bash
brew tap dexrelay-app/dexrelay && brew install dexrelay && dexrelay install
```

Fallback:

```bash
curl -fsSL https://assets.dexrelay.app/install.sh | bash
```

## Canonical pairing command

```bash
dexrelay pair
```

## Canonical repair flow

Start here:

```bash
dexrelay status
dexrelay repair
```

If repair is insufficient:

```bash
dexrelay install
```

## Canonical uninstall command

```bash
dexrelay uninstall
```

This removes the DexRelay runtime, launch agents, logs, and the Homebrew CLI if it was installed through Homebrew.

## Keep-awake controls

```bash
dexrelay wake on
dexrelay wake off
dexrelay wake status
```

## Advanced / internal

```bash
dexrelay relay-pair
```

## Public references

- `https://dexrelay.app/help`
- `https://dexrelay.app/dexrelaysetup`
- `https://dexrelay.app/dexrelay-skill.md`
