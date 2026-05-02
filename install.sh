#!/usr/bin/env bash
set -euo pipefail

# Homebrew auto-update is often the slowest part of a clean office-Mac install,
# and it can sit quietly for minutes before we even start DexRelay runtime setup.
export HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-1}"

DEFAULT_RUNTIME_ROOT="$HOME/Library/Application Support/DexRelay/runtime"

runtime_root_ready() {
  local root="$1"
  [[ -f "$root/scripts/governancectl.py" || -f "$root/helper/helper.py" || -f "$root/bin/start-helper.sh" ]]
}

resolve_runtime_root() {
  if [[ -n "${CODEX_RELAY_ROOT:-}" ]]; then
    printf '%s\n' "$CODEX_RELAY_ROOT"
  else
    printf '%s\n' "$DEFAULT_RUNTIME_ROOT"
  fi
}

INSTALL_ROOT="$(resolve_runtime_root)"
BIN_DIR="$INSTALL_ROOT/bin"
BRIDGE_DIR="$INSTALL_ROOT/bridge"
HELPER_DIR="$INSTALL_ROOT/helper"
SCRIPTS_DIR="$INSTALL_ROOT/scripts"
HEALTH_UI_DIR="$INSTALL_ROOT/health-ui"
RELAY_STATE_DIR="$INSTALL_ROOT/relay"
LOG_DIR="$HOME/Library/Logs/CodexRelayBootstrap"
HELPER_LOG_DIR="$HOME/Library/Logs/CodexRelayHelper"
HELPER_STATE_DIR="${CODEX_RELAY_HELPER_STATE_DIR:-$HOME/Library/Application Support/CodexRelayHelper}"
OTA_PUBLIC_ROOT="${CODEX_RELAY_OTA_PUBLIC_ROOT:-$HELPER_STATE_DIR/ota/public}"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
BRIDGE_LABEL="${CODEX_RELAY_LABEL:-com.codexrelay.bootstrap}"
BRIDGE_PLIST="$LAUNCH_AGENTS_DIR/$BRIDGE_LABEL.plist"
HELPER_LABEL="${CODEX_RELAY_HELPER_LABEL:-com.codexrelay.setuphelper}"
HELPER_PLIST="$LAUNCH_AGENTS_DIR/$HELPER_LABEL.plist"
HEALTHD_LABEL="${CODEX_RELAY_HEALTHD_LABEL:-com.codexrelay.healthd}"
HEALTHD_PLIST="$LAUNCH_AGENTS_DIR/$HEALTHD_LABEL.plist"
WATCHDOG_LABEL="${CODEX_RELAY_WATCHDOG_LABEL:-com.codexrelay.watchdog.bootstrap}"
WATCHDOG_PLIST="$LAUNCH_AGENTS_DIR/$WATCHDOG_LABEL.plist"
RELAY_SERVER_LABEL="${CODEX_RELAY_RELAY_SERVER_LABEL:-com.codexrelay.relayserver.bootstrap}"
RELAY_SERVER_PLIST="$LAUNCH_AGENTS_DIR/$RELAY_SERVER_LABEL.plist"
RELAY_CONNECTOR_LABEL="${CODEX_RELAY_RELAY_CONNECTOR_LABEL:-com.codexrelay.relayconnector.bootstrap}"
RELAY_CONNECTOR_PLIST="$LAUNCH_AGENTS_DIR/$RELAY_CONNECTOR_LABEL.plist"
QUIC_GATEWAY_LABEL="${CODEX_RELAY_QUIC_GATEWAY_LABEL:-com.dexrelay.quicgateway.bootstrap}"
QUIC_GATEWAY_PLIST="$LAUNCH_AGENTS_DIR/$QUIC_GATEWAY_LABEL.plist"
ENABLE_QUIC="${CODEX_RELAY_ENABLE_QUIC:-0}"
KEEP_AWAKE="${CODEX_RELAY_KEEP_AWAKE:-1}"
AWAKE_LABEL="${CODEX_RELAY_KEEP_AWAKE_LABEL:-com.codexrelay.keepawake.bootstrap}"
AWAKE_PLIST="$LAUNCH_AGENTS_DIR/$AWAKE_LABEL.plist"
SETUP_BASE_URL="${CODEX_RELAY_SETUP_BASE_URL:-https://assets.dexrelay.app}"
DEFAULT_PROJECTS_ROOT="${CODEX_RELAY_PROJECTS_ROOT:-$HOME/src}"
ADMIN_PROJECT_ROOT="${CODEX_RELAY_ADMIN_PROJECT_ROOT:-$DEFAULT_PROJECTS_ROOT/DexRelay Admin}"
BRIDGE_PORT="${CODEX_RELAY_BRIDGE_PORT:-4615}"
HELPER_PORT="${CODEX_RELAY_HELPER_PORT:-4616}"
HEALTH_PORT="${CODEX_HEALTH_PORT:-4610}"
RELAY_SERVER_PORT="${CODEX_RELAY_SERVER_PORT:-4620}"
RELAY_SERVER_PATH="${CODEX_RELAY_SERVER_PATH:-/relay}"
QUIC_GATEWAY_PORT="${CODEX_RELAY_QUIC_PORT:-4617}"
RUNTIME_MANIFEST_PATH="$INSTALL_ROOT/runtime-manifest.json"
INSTALL_MODE="${CODEX_RELAY_INSTALL_MODE:-direct-install-script}"
AUTO_INSTALL="${CODEX_RELAY_AUTO_INSTALL:-0}"
DEXRELAY_PAYLOAD_VERSION="${CODEX_RELAY_PAYLOAD_VERSION:-0.1.55}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
LOCAL_PAYLOAD_ROOT="${CODEX_RELAY_LOCAL_PAYLOAD_ROOT:-$SCRIPT_DIR}"
LOCAL_BRIDGE_SOURCE="$LOCAL_PAYLOAD_ROOT/bridge.js"
LOCAL_RELAY_SERVER_SOURCE="$LOCAL_PAYLOAD_ROOT/relay-server.js"
LOCAL_RELAY_CONNECTOR_SOURCE="$LOCAL_PAYLOAD_ROOT/relay-connector.js"
LOCAL_QUIC_GATEWAY_SOURCE="$LOCAL_PAYLOAD_ROOT/quic-bridge-gateway.swift"
LOCAL_PACKAGE_SOURCE="$LOCAL_PAYLOAD_ROOT/package.json"
LOCAL_CODEX_FAST_SOURCE="$LOCAL_PAYLOAD_ROOT/codex-fast.py"
LOCAL_HELPER_SOURCE="$LOCAL_PAYLOAD_ROOT/helper.py"
LOCAL_CREATE_PROJECT_SOURCE="$LOCAL_PAYLOAD_ROOT/create-mac-project.sh"
LOCAL_GIT_AUTOMATION_SOURCE="$LOCAL_PAYLOAD_ROOT/git-project-automation.sh"
LOCAL_GOVERNANCECTL_SOURCE="$LOCAL_PAYLOAD_ROOT/governancectl.py"
LOCAL_SERVICES_REGISTRY_SOURCE="$LOCAL_PAYLOAD_ROOT/services.registry.json"
LOCAL_SERVICECTL_SOURCE="$LOCAL_PAYLOAD_ROOT/servicectl.py"
LOCAL_REBUILD_WORKSPACE_SOURCE="$LOCAL_PAYLOAD_ROOT/rebuild-workspace-services.py"
LOCAL_MIGRATE_DEXRELAY_SOURCE="$LOCAL_PAYLOAD_ROOT/migrate-dexrelay-state.py"
LOCAL_XCODE_DEVDIR_SOURCE="$LOCAL_PAYLOAD_ROOT/xcode-devdir.sh"
LOCAL_RUN_IOS_DEVICE_SOURCE="$LOCAL_PAYLOAD_ROOT/run-ios-device.sh"
LOCAL_RUN_IOS_ON_PHONE_SOURCE="$LOCAL_PAYLOAD_ROOT/run-ios-on-phone.sh"
LOCAL_PUBLISH_IOS_OTA_SOURCE="$LOCAL_PAYLOAD_ROOT/publish-ios-adhoc-ota.sh"
LOCAL_PREPARE_IOS_TESTFLIGHT_SOURCE="$LOCAL_PAYLOAD_ROOT/prepare-ios-testflight.py"
LOCAL_IOS_TESTFLIGHT_COMMON_SOURCE="$LOCAL_PAYLOAD_ROOT/ios_testflight_common.py"
LOCAL_HEALTHD_SOURCE="$LOCAL_PAYLOAD_ROOT/codex-health-daemon.py"
LOCAL_HEALTH_UI_INDEX_SOURCE="$LOCAL_PAYLOAD_ROOT/health-ui-index.html"
LOCAL_HEALTH_UI_APP_SOURCE="$LOCAL_PAYLOAD_ROOT/health-ui-app.js"
LOCAL_HEALTH_UI_STYLES_SOURCE="$LOCAL_PAYLOAD_ROOT/health-ui-styles.css"
REMOTE_BRIDGE_SOURCE="$SETUP_BASE_URL/bridge.js"
REMOTE_RELAY_SERVER_SOURCE="$SETUP_BASE_URL/relay-server.js"
REMOTE_RELAY_CONNECTOR_SOURCE="$SETUP_BASE_URL/relay-connector.js"
REMOTE_QUIC_GATEWAY_SOURCE="$SETUP_BASE_URL/quic-bridge-gateway.swift"
REMOTE_PACKAGE_SOURCE="$SETUP_BASE_URL/package.json"
REMOTE_CODEX_FAST_SOURCE="$SETUP_BASE_URL/codex-fast.py"
REMOTE_HELPER_SOURCE="$SETUP_BASE_URL/helper.py"
REMOTE_CREATE_PROJECT_SOURCE="$SETUP_BASE_URL/create-mac-project.sh"
REMOTE_GIT_AUTOMATION_SOURCE="$SETUP_BASE_URL/git-project-automation.sh"
REMOTE_GOVERNANCECTL_SOURCE="$SETUP_BASE_URL/governancectl.py"
REMOTE_SERVICES_REGISTRY_SOURCE="$SETUP_BASE_URL/services.registry.json"
REMOTE_SERVICECTL_SOURCE="$SETUP_BASE_URL/servicectl.py"
REMOTE_REBUILD_WORKSPACE_SOURCE="$SETUP_BASE_URL/rebuild-workspace-services.py"
REMOTE_MIGRATE_DEXRELAY_SOURCE="$SETUP_BASE_URL/migrate-dexrelay-state.py"
REMOTE_XCODE_DEVDIR_SOURCE="$SETUP_BASE_URL/xcode-devdir.sh"
REMOTE_RUN_IOS_DEVICE_SOURCE="$SETUP_BASE_URL/run-ios-device.sh"
REMOTE_RUN_IOS_ON_PHONE_SOURCE="$SETUP_BASE_URL/run-ios-on-phone.sh"
REMOTE_PUBLISH_IOS_OTA_SOURCE="$SETUP_BASE_URL/publish-ios-adhoc-ota.sh"
REMOTE_PREPARE_IOS_TESTFLIGHT_SOURCE="$SETUP_BASE_URL/prepare-ios-testflight.py"
REMOTE_IOS_TESTFLIGHT_COMMON_SOURCE="$SETUP_BASE_URL/ios_testflight_common.py"
REMOTE_HEALTHD_SOURCE="$SETUP_BASE_URL/codex-health-daemon.py"
REMOTE_HEALTH_UI_INDEX_SOURCE="$SETUP_BASE_URL/health-ui-index.html"
REMOTE_HEALTH_UI_APP_SOURCE="$SETUP_BASE_URL/health-ui-app.js"
REMOTE_HEALTH_UI_STYLES_SOURCE="$SETUP_BASE_URL/health-ui-styles.css"

log() {
  printf "\n[%s] %s\n" "codex-relay-setup" "$1"
}

phase() {
  log "Phase $1"
}

quic_enabled() {
  case "$(printf '%s' "$ENABLE_QUIC" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

warn() {
  printf "\n[%s] warning: %s\n" "codex-relay-setup" "$1" >&2
}

fail() {
  printf "\n[%s] error: %s\n" "codex-relay-setup" "$1" >&2
  exit 1
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "This installer currently supports macOS only."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

resolve_tailscale_cli() {
  for candidate in "/Applications/Tailscale.app/Contents/MacOS/Tailscale" "/opt/homebrew/bin/tailscale" "/usr/local/bin/tailscale"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  if command_exists tailscale; then
    command -v tailscale
    return 0
  fi
  return 1
}

brew_prefix() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    echo /opt/homebrew
  elif [[ -x /usr/local/bin/brew ]]; then
    echo /usr/local
  else
    return 1
  fi
}

load_brew_env() {
  local prefix
  prefix="$(brew_prefix)" || return 0
  eval "$("$prefix/bin/brew" shellenv)"
}

ensure_homebrew() {
  if command_exists brew; then
    load_brew_env
    return 0
  fi

  log "Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  load_brew_env
  command_exists brew || fail "Homebrew installation finished but brew is not on PATH."
}

ensure_formula() {
  local formula="$1"
  if brew list "$formula" >/dev/null 2>&1; then
    return 0
  fi

  log "Installing $formula"
  brew install "$formula"
}

ensure_tailscale_cli_on_path() {
  local tailscale_cli="$1"
  if command_exists tailscale && tailscale version >/dev/null 2>&1; then
    return 0
  elif command_exists tailscale; then
    warn "Existing tailscale command is present but unhealthy; replacing it with a DexRelay-managed wrapper."
  fi

  local wrapper_target=""
  local existing_path=""
  existing_path="$(command -v tailscale 2>/dev/null || true)"
  if [[ -n "$existing_path" && -w "$existing_path" ]]; then
    wrapper_target="$existing_path"
  fi

  for candidate in "/opt/homebrew/bin/tailscale" "/usr/local/bin/tailscale"; do
    [[ -n "$wrapper_target" ]] && break
    local candidate_dir
    candidate_dir="$(dirname "$candidate")"
    if [[ -d "$candidate_dir" && -w "$candidate_dir" ]]; then
      wrapper_target="$candidate"
      break
    fi
  done

  if [[ -z "$wrapper_target" ]]; then
    warn "Tailscale CLI is installed but could not be exposed on PATH automatically."
    return 0
  fi

  if [[ -L "$wrapper_target" ]]; then
    rm -f "$wrapper_target" || {
      warn "Failed to remove legacy tailscale symlink at $wrapper_target."
      return 0
    }
  fi

  if ! cat >"$wrapper_target" <<EOF
#!/usr/bin/env bash
exec "$tailscale_cli" "\$@"
EOF
  then
    warn "Failed to write tailscale PATH wrapper at $wrapper_target."
    return 0
  fi

  chmod +x "$wrapper_target" || {
    warn "Failed to create tailscale PATH wrapper at $wrapper_target."
    return 0
  }

  log "Installed tailscale PATH wrapper at $wrapper_target"
}

should_install_tailscale_now() {
  if [[ "${CODEX_RELAY_INSTALL_TAILSCALE:-}" == "1" ]]; then
    return 0
  fi

  if [[ "${CODEX_RELAY_AUTO_INSTALL:-}" == "1" || "${CODEX_RELAY_INSTALL_MODE:-}" == "npm-postinstall" ]]; then
    return 1
  fi

  return 0
}

ensure_tailscale_installed() {
  local tailscale_cli=""
  tailscale_cli="$(resolve_tailscale_cli || true)"
  if [[ -n "$tailscale_cli" ]]; then
    ensure_tailscale_cli_on_path "$tailscale_cli"
    log "Tailscale CLI already available at $tailscale_cli"
    return 0
  fi

  if ! should_install_tailscale_now; then
    warn "Tailscale is not installed; continuing DexRelay install without blocking npm. Local Wi-Fi pairing still works. Install Tailscale later for remote access, or rerun with CODEX_RELAY_INSTALL_TAILSCALE=1."
    return 0
  fi

  log "Installing Tailscale"
  if ! brew list --cask tailscale >/dev/null 2>&1; then
    brew install --cask tailscale
  fi

  tailscale_cli="$(resolve_tailscale_cli || true)"
  [[ -n "$tailscale_cli" ]] || fail "Tailscale installation finished, but tailscale CLI was not found."
  ensure_tailscale_cli_on_path "$tailscale_cli"
  log "Tailscale CLI installed at $tailscale_cli"
}

ensure_tailscale_connected() {
  local tailscale_cli=""
  tailscale_cli="$(resolve_tailscale_cli || true)"
  if [[ -z "$tailscale_cli" ]]; then
    warn "tailscale CLI not found after install. Run dexrelay repair after confirming Tailscale.app is installed."
    return 0
  fi

  if ! "$tailscale_cli" status --json >/dev/null 2>&1; then
    warn "Tailscale does not appear connected yet. Finish Tailscale setup before using Codex Relay."
    return 0
  fi

  log "Tailscale connection confirmed"
}

ensure_tailscale_serve_enabled() {
  local tailscale_cli=""
  local serve_status_file=""
  local serve_enable_file=""
  tailscale_cli="$(resolve_tailscale_cli || true)"
  if [[ -z "$tailscale_cli" ]]; then
    warn "tailscale CLI not found; skipping Tailscale Serve setup."
    return 0
  fi

  if ! "$tailscale_cli" status --json >/dev/null 2>&1; then
    warn "Tailscale is not connected; skipping Tailscale Serve setup."
    return 0
  fi

  serve_status_file="$(mktemp -t dexrelay-serve-status.XXXXXX)"
  if ! "$tailscale_cli" serve status >"$serve_status_file" 2>&1; then
    if grep -qi "serve is not enabled on your tailnet" "$serve_status_file"; then
      warn "Tailscale Serve is disabled by tailnet policy. Enable it at https://login.tailscale.com/f/serve"
    elif grep -qi "unknown command\\|unknown subcommand" "$serve_status_file"; then
      warn "Installed Tailscale CLI does not support 'tailscale serve'. Upgrade Tailscale to enable OTA publish over tailnet HTTPS."
    else
      warn "Could not verify Tailscale Serve support. Continuing install."
    fi
    rm -f "$serve_status_file"
    return 0
  fi
  rm -f "$serve_status_file"

  serve_enable_file="$(mktemp -t dexrelay-serve-enable.XXXXXX)"
  if "$tailscale_cli" serve --bg --yes --set-path "$RELAY_SERVER_PATH" "$RELAY_SERVER_PORT" >"$serve_enable_file" 2>&1; then
    log "Tailscale Serve default route configured at $RELAY_SERVER_PATH -> 127.0.0.1:$RELAY_SERVER_PORT"
  else
    if grep -qi "serve is not enabled on your tailnet" "$serve_enable_file"; then
      warn "Tailscale Serve is disabled by tailnet policy. Enable it at https://login.tailscale.com/f/serve"
    else
      warn "Failed to configure default Tailscale Serve route. You can still run dexrelay; OTA publish may require manual tailscale serve setup."
    fi
  fi
  rm -f "$serve_enable_file"
}

ensure_codex() {
  if command_exists codex; then
    log "Codex CLI already available at $(command -v codex)"
    return 0
  fi

  log "Installing Codex CLI"
  if brew info codex >/dev/null 2>&1; then
    brew install codex || true
  fi

  if ! command_exists codex; then
    npm install -g @openai/codex
  fi

  command_exists codex || fail "Codex CLI install failed."
}

write_bridge_package_json() {
  local package_path="$BRIDGE_DIR/package.json"
  cat >"$package_path" <<'EOF'
{
  "name": "codexrelay-bridge-runtime",
  "version": "1.0.0",
  "private": true,
  "type": "commonjs",
  "dependencies": {
    "qrcode-terminal": "^0.12.0",
    "ws": "^8.19.0"
  }
}
EOF
}

install_bridge_assets() {
  mkdir -p "$BRIDGE_DIR"

  if [[ -f "$LOCAL_BRIDGE_SOURCE" ]]; then
    log "Copying bridge from bundled DexRelay payload"
    cp "$LOCAL_BRIDGE_SOURCE" "$BRIDGE_DIR/bridge.js"
  else
    log "Downloading bridge runtime from $REMOTE_BRIDGE_SOURCE"
    curl -fsSL "$REMOTE_BRIDGE_SOURCE" -o "$BRIDGE_DIR/bridge.js"
  fi

  if [[ -f "$LOCAL_RELAY_SERVER_SOURCE" ]]; then
    cp "$LOCAL_RELAY_SERVER_SOURCE" "$BRIDGE_DIR/relay-server.js"
  else
    curl -fsSL "$REMOTE_RELAY_SERVER_SOURCE" -o "$BRIDGE_DIR/relay-server.js"
  fi

  if [[ -f "$LOCAL_RELAY_CONNECTOR_SOURCE" ]]; then
    cp "$LOCAL_RELAY_CONNECTOR_SOURCE" "$BRIDGE_DIR/relay-connector.js"
  else
    curl -fsSL "$REMOTE_RELAY_CONNECTOR_SOURCE" -o "$BRIDGE_DIR/relay-connector.js"
  fi

  if [[ -f "$LOCAL_QUIC_GATEWAY_SOURCE" ]]; then
    cp "$LOCAL_QUIC_GATEWAY_SOURCE" "$BRIDGE_DIR/quic-bridge-gateway.swift"
  else
    curl -fsSL "$REMOTE_QUIC_GATEWAY_SOURCE" -o "$BRIDGE_DIR/quic-bridge-gateway.swift"
  fi

  write_bridge_package_json
  log "Installing bridge dependencies"
  if ! DEXRELAY_SKIP_POSTINSTALL=1 npm install --prefix "$BRIDGE_DIR" --omit=dev; then
    warn "Bridge dependency install failed. DexRelay will try the bundled npm package dependencies and can be repaired with dexrelay repair."
  fi
  if ! NODE_PATH="$BRIDGE_DIR/node_modules:$LOCAL_PAYLOAD_ROOT/node_modules:${NODE_PATH:-}" node -e 'require("ws"); require("qrcode-terminal")' >/dev/null 2>&1; then
    warn "Bridge dependencies are not fully available yet. Run dexrelay repair if bridge startup fails."
  fi
}

install_helper_assets() {
  mkdir -p "$HELPER_DIR"

  if [[ -f "$LOCAL_HELPER_SOURCE" ]]; then
    log "Copying setup helper from bundled DexRelay payload"
    cp "$LOCAL_HELPER_SOURCE" "$HELPER_DIR/helper.py"
  else
    log "Downloading setup helper from $REMOTE_HELPER_SOURCE"
    curl -fsSL "$REMOTE_HELPER_SOURCE" -o "$HELPER_DIR/helper.py"
  fi
}

install_runtime_scripts() {
  mkdir -p "$SCRIPTS_DIR" "$INSTALL_ROOT/command-center" "$RELAY_STATE_DIR" "$HEALTH_UI_DIR"

  if [[ -f "$LOCAL_CREATE_PROJECT_SOURCE" ]]; then
    cp "$LOCAL_CREATE_PROJECT_SOURCE" "$SCRIPTS_DIR/create-mac-project.sh"
  else
    curl -fsSL "$REMOTE_CREATE_PROJECT_SOURCE" -o "$SCRIPTS_DIR/create-mac-project.sh"
  fi

  if [[ -f "$LOCAL_GIT_AUTOMATION_SOURCE" ]]; then
    cp "$LOCAL_GIT_AUTOMATION_SOURCE" "$SCRIPTS_DIR/git-project-automation.sh"
  else
    curl -fsSL "$REMOTE_GIT_AUTOMATION_SOURCE" -o "$SCRIPTS_DIR/git-project-automation.sh"
  fi

  if [[ -f "$LOCAL_GOVERNANCECTL_SOURCE" ]]; then
    cp "$LOCAL_GOVERNANCECTL_SOURCE" "$SCRIPTS_DIR/governancectl.py"
  else
    curl -fsSL "$REMOTE_GOVERNANCECTL_SOURCE" -o "$SCRIPTS_DIR/governancectl.py"
  fi

  if [[ -f "$LOCAL_SERVICES_REGISTRY_SOURCE" ]]; then
    cp "$LOCAL_SERVICES_REGISTRY_SOURCE" "$SCRIPTS_DIR/services.registry.json"
  else
    curl -fsSL "$REMOTE_SERVICES_REGISTRY_SOURCE" -o "$SCRIPTS_DIR/services.registry.json"
  fi

  if [[ -f "$LOCAL_SERVICECTL_SOURCE" ]]; then
    cp "$LOCAL_SERVICECTL_SOURCE" "$SCRIPTS_DIR/servicectl.py"
  else
    curl -fsSL "$REMOTE_SERVICECTL_SOURCE" -o "$SCRIPTS_DIR/servicectl.py"
  fi

  if [[ -f "$LOCAL_REBUILD_WORKSPACE_SOURCE" ]]; then
    cp "$LOCAL_REBUILD_WORKSPACE_SOURCE" "$SCRIPTS_DIR/rebuild-workspace-services.py"
  else
    curl -fsSL "$REMOTE_REBUILD_WORKSPACE_SOURCE" -o "$SCRIPTS_DIR/rebuild-workspace-services.py"
  fi

  if [[ -f "$LOCAL_MIGRATE_DEXRELAY_SOURCE" ]]; then
    cp "$LOCAL_MIGRATE_DEXRELAY_SOURCE" "$SCRIPTS_DIR/migrate-dexrelay-state.py"
  else
    curl -fsSL "$REMOTE_MIGRATE_DEXRELAY_SOURCE" -o "$SCRIPTS_DIR/migrate-dexrelay-state.py"
  fi

  if [[ -f "$LOCAL_XCODE_DEVDIR_SOURCE" ]]; then
    cp "$LOCAL_XCODE_DEVDIR_SOURCE" "$SCRIPTS_DIR/xcode-devdir.sh"
  else
    curl -fsSL "$REMOTE_XCODE_DEVDIR_SOURCE" -o "$SCRIPTS_DIR/xcode-devdir.sh"
  fi

  if [[ -f "$LOCAL_RUN_IOS_DEVICE_SOURCE" ]]; then
    cp "$LOCAL_RUN_IOS_DEVICE_SOURCE" "$SCRIPTS_DIR/run-ios-device.sh"
  else
    curl -fsSL "$REMOTE_RUN_IOS_DEVICE_SOURCE" -o "$SCRIPTS_DIR/run-ios-device.sh"
  fi

  if [[ -f "$LOCAL_RUN_IOS_ON_PHONE_SOURCE" ]]; then
    cp "$LOCAL_RUN_IOS_ON_PHONE_SOURCE" "$SCRIPTS_DIR/run-ios-on-phone.sh"
  else
    curl -fsSL "$REMOTE_RUN_IOS_ON_PHONE_SOURCE" -o "$SCRIPTS_DIR/run-ios-on-phone.sh"
  fi

  if [[ -f "$LOCAL_PUBLISH_IOS_OTA_SOURCE" ]]; then
    cp "$LOCAL_PUBLISH_IOS_OTA_SOURCE" "$SCRIPTS_DIR/publish-ios-adhoc-ota.sh"
  else
    curl -fsSL "$REMOTE_PUBLISH_IOS_OTA_SOURCE" -o "$SCRIPTS_DIR/publish-ios-adhoc-ota.sh"
  fi

  if [[ -f "$LOCAL_PREPARE_IOS_TESTFLIGHT_SOURCE" ]]; then
    cp "$LOCAL_PREPARE_IOS_TESTFLIGHT_SOURCE" "$SCRIPTS_DIR/prepare-ios-testflight.py"
  else
    curl -fsSL "$REMOTE_PREPARE_IOS_TESTFLIGHT_SOURCE" -o "$SCRIPTS_DIR/prepare-ios-testflight.py"
  fi

  if [[ -f "$LOCAL_IOS_TESTFLIGHT_COMMON_SOURCE" ]]; then
    cp "$LOCAL_IOS_TESTFLIGHT_COMMON_SOURCE" "$SCRIPTS_DIR/ios_testflight_common.py"
  else
    curl -fsSL "$REMOTE_IOS_TESTFLIGHT_COMMON_SOURCE" -o "$SCRIPTS_DIR/ios_testflight_common.py"
  fi

  if [[ -f "$LOCAL_CODEX_FAST_SOURCE" ]]; then
    cp "$LOCAL_CODEX_FAST_SOURCE" "$SCRIPTS_DIR/codex-fast.py"
  else
    curl -fsSL "$REMOTE_CODEX_FAST_SOURCE" -o "$SCRIPTS_DIR/codex-fast.py"
  fi

  if [[ -f "$LOCAL_HEALTHD_SOURCE" ]]; then
    cp "$LOCAL_HEALTHD_SOURCE" "$SCRIPTS_DIR/codex-health-daemon.py"
  else
    curl -fsSL "$REMOTE_HEALTHD_SOURCE" -o "$SCRIPTS_DIR/codex-health-daemon.py"
  fi

  if [[ -f "$LOCAL_HEALTH_UI_INDEX_SOURCE" ]]; then
    cp "$LOCAL_HEALTH_UI_INDEX_SOURCE" "$HEALTH_UI_DIR/index.html"
  else
    curl -fsSL "$REMOTE_HEALTH_UI_INDEX_SOURCE" -o "$HEALTH_UI_DIR/index.html"
  fi

  if [[ -f "$LOCAL_HEALTH_UI_APP_SOURCE" ]]; then
    cp "$LOCAL_HEALTH_UI_APP_SOURCE" "$HEALTH_UI_DIR/app.js"
  else
    curl -fsSL "$REMOTE_HEALTH_UI_APP_SOURCE" -o "$HEALTH_UI_DIR/app.js"
  fi

  if [[ -f "$LOCAL_HEALTH_UI_STYLES_SOURCE" ]]; then
    cp "$LOCAL_HEALTH_UI_STYLES_SOURCE" "$HEALTH_UI_DIR/styles.css"
  else
    curl -fsSL "$REMOTE_HEALTH_UI_STYLES_SOURCE" -o "$HEALTH_UI_DIR/styles.css"
  fi

  chmod +x "$SCRIPTS_DIR/create-mac-project.sh" "$SCRIPTS_DIR/git-project-automation.sh" "$SCRIPTS_DIR/governancectl.py" "$SCRIPTS_DIR/servicectl.py" "$SCRIPTS_DIR/rebuild-workspace-services.py" "$SCRIPTS_DIR/migrate-dexrelay-state.py" "$SCRIPTS_DIR/xcode-devdir.sh" "$SCRIPTS_DIR/run-ios-device.sh" "$SCRIPTS_DIR/run-ios-on-phone.sh" "$SCRIPTS_DIR/publish-ios-adhoc-ota.sh" "$SCRIPTS_DIR/prepare-ios-testflight.py" "$SCRIPTS_DIR/codex-fast.py" "$SCRIPTS_DIR/codex-health-daemon.py"
  python3 "$SCRIPTS_DIR/servicectl.py" sync-conf >/dev/null 2>&1 || true
}

migrate_project_state() {
  local migration_script="$SCRIPTS_DIR/migrate-dexrelay-state.py"
  if [[ ! -f "$migration_script" ]]; then
    warn "DexRelay state migration script is missing from $SCRIPTS_DIR; skipping legacy project state migration."
    return 0
  fi
  if [[ ! -d "$DEFAULT_PROJECTS_ROOT" ]]; then
    return 0
  fi

  log "Migrating DexRelay-owned project state from .codex to .dexrelay under $DEFAULT_PROJECTS_ROOT"
  if ! python3 "$migration_script" "$DEFAULT_PROJECTS_ROOT"; then
    warn "DexRelay project-state migration reported an error. Existing installs may still need manual cleanup."
  fi
}

write_runtime_manifest() {
  local installed_at
  local quic_port_json="null"
  local quic_enabled_json="false"
  mkdir -p "$INSTALL_ROOT"
  installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if quic_enabled; then
    quic_port_json="$QUIC_GATEWAY_PORT"
    quic_enabled_json="true"
  fi

  cat >"$RUNTIME_MANIFEST_PATH" <<EOF
{
  "version": 1,
  "installMode": $(python3 - <<'PY' "$INSTALL_MODE"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "autoInstall": $(python3 - <<'PY' "$AUTO_INSTALL"
import json, sys
value = sys.argv[1].strip().lower() in {"1", "true", "yes"}
print("true" if value else "false")
PY
),
  "installedAt": $(python3 - <<'PY' "$installed_at"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "runtimeRoot": $(python3 - <<'PY' "$INSTALL_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "defaultRuntimeRoot": $(python3 - <<'PY' "$DEFAULT_RUNTIME_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "projectsRoot": $(python3 - <<'PY' "$DEFAULT_PROJECTS_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "adminProjectRoot": $(python3 - <<'PY' "$ADMIN_PROJECT_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "helperPort": $HELPER_PORT,
  "bridgePort": $BRIDGE_PORT,
  "quicEnabled": $quic_enabled_json,
  "quicPort": $quic_port_json,
  "healthPort": $HEALTH_PORT,
  "relayServerPort": $RELAY_SERVER_PORT
}
EOF
}

scaffold_admin_project() {
  local codex_dir="$ADMIN_PROJECT_ROOT/.dexrelay"
  local tools_dir="$ADMIN_PROJECT_ROOT/tools"

  mkdir -p "$codex_dir" "$tools_dir" "$ADMIN_PROJECT_ROOT/state"

  if [[ ! -f "$tools_dir/dexrelay-env.sh" ]]; then
    cat >"$tools_dir/dexrelay-env.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

DEFAULT_RUNTIME_ROOT="$HOME/Library/Application Support/DexRelay/runtime"

runtime_root_ready() {
  local root="$1"
  [[ -f "$root/scripts/governancectl.py" || -f "$root/helper/helper.py" || -f "$root/bin/start-helper.sh" ]]
}

resolve_dexrelay_runtime_root() {
  if [[ -n "${CODEX_RELAY_ROOT:-}" ]]; then
    printf '%s\n' "$CODEX_RELAY_ROOT"
  else
    printf '%s\n' "$DEFAULT_RUNTIME_ROOT"
  fi
}

DEXRELAY_RUNTIME_ROOT="$(resolve_dexrelay_runtime_root)"
DEXRELAY_PROJECTS_ROOT="${CODEX_RELAY_PROJECTS_ROOT:-$HOME/src}"
DEXRELAY_ADMIN_PROJECT_ROOT="${CODEX_RELAY_ADMIN_PROJECT_ROOT:-$DEXRELAY_PROJECTS_ROOT/DexRelay Admin}"
export DEXRELAY_RUNTIME_ROOT DEXRELAY_PROJECTS_ROOT DEXRELAY_ADMIN_PROJECT_ROOT
EOF
    chmod +x "$tools_dir/dexrelay-env.sh"
  fi

  if [[ ! -f "$tools_dir/fix-dexrelay.sh" ]]; then
    cat >"$tools_dir/fix-dexrelay.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec dexrelay repair
EOF
    chmod +x "$tools_dir/fix-dexrelay.sh"
  fi

  if [[ ! -f "$tools_dir/dexrelay-status.sh" ]]; then
    cat >"$tools_dir/dexrelay-status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec dexrelay status
EOF
    chmod +x "$tools_dir/dexrelay-status.sh"
  fi

  if [[ ! -f "$tools_dir/dexrelay-doctor.sh" ]]; then
    cat >"$tools_dir/dexrelay-doctor.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec dexrelay doctor
EOF
    chmod +x "$tools_dir/dexrelay-doctor.sh"
  fi

  if [[ ! -f "$tools_dir/open-health-ui.sh" ]]; then
    cat >"$tools_dir/open-health-ui.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
open "http://127.0.0.1:4610"
EOF
    chmod +x "$tools_dir/open-health-ui.sh"
  fi

  if [[ ! -f "$tools_dir/refresh-project-setup.sh" ]]; then
    cat >"$tools_dir/refresh-project-setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/dexrelay-env.sh"

GOVERNANCECTL="$DEXRELAY_RUNTIME_ROOT/scripts/governancectl.py"
if [[ ! -f "$GOVERNANCECTL" ]]; then
  echo "Missing governancectl.py at $GOVERNANCECTL" >&2
  exit 1
fi

if [[ $# -gt 0 ]]; then
  exec python3 "$GOVERNANCECTL" update-project --project-path "$1" --write-runbook
fi

exec python3 "$GOVERNANCECTL" update-all --base-dir "$DEXRELAY_PROJECTS_ROOT" --adopt-missing --write-runbooks
EOF
    chmod +x "$tools_dir/refresh-project-setup.sh"
  fi

  if [[ ! -f "$ADMIN_PROJECT_ROOT/README.md" ]]; then
    cat >"$ADMIN_PROJECT_ROOT/README.md" <<EOF
# DexRelay Admin

This is the support workspace for DexRelay on this Mac.

Use it when you want Codex to diagnose or repair:

- bridge or helper failures
- project setup drift
- backend services that are down
- Tailscale connectivity problems
- stale project endpoints

## Runtime split

- DexRelay runtime: \`$INSTALL_ROOT\`
- DexRelay Admin workspace: \`$ADMIN_PROJECT_ROOT\`
- User projects root: \`$DEFAULT_PROJECTS_ROOT\`

DexRelay keeps the runtime separate so upgrades and repairs do not depend on a user-facing project folder.

## Useful prompts

- Why is DexRelay not connecting from my phone?
- Fix DexRelay and bring all required services back up.
- Refresh setup for my projects and repair missing governance.
- Why is this app still pointing at an old Tailscale host?
- Check whether my Mac helper, bridge, and health daemon are healthy.

## Local tools

- \`./tools/fix-dexrelay.sh\`
- \`./tools/dexrelay-status.sh\`
- \`./tools/dexrelay-doctor.sh\`
- \`./tools/open-health-ui.sh\`
- \`./tools/refresh-project-setup.sh\`
EOF
  fi

  if [[ ! -f "$ADMIN_PROJECT_ROOT/.gitignore" ]]; then
    cat >"$ADMIN_PROJECT_ROOT/.gitignore" <<'EOF'
state/*.json
state/*.log
EOF
  fi

  if [[ ! -f "$codex_dir/project-runbook.json" ]]; then
    cat >"$codex_dir/project-runbook.json" <<'EOF'
{
  "version": 1,
  "title": "DexRelay Admin Runbook",
  "summary": "Use this workspace to diagnose and repair DexRelay setup, project access, and runtime issues on this Mac.",
  "primaryActionID": "fix-dexrelay",
  "actions": [
    {
      "id": "fix-dexrelay",
      "title": "Fix DexRelay",
      "subtitle": "Repair the Mac runtime, restart launch agents, and recheck helper access.",
      "icon": "wrench.and.screwdriver",
      "kind": "shell",
      "command": "./tools/fix-dexrelay.sh",
      "cwd": ".",
      "executionMode": "direct-then-codex",
      "timeoutMs": 1200000,
      "showInQuickActions": true
    },
    {
      "id": "dexrelay-status",
      "title": "Show DexRelay Status",
      "subtitle": "Print bridge, helper, Tailscale, and launch-agent health.",
      "icon": "waveform.path.ecg",
      "kind": "shell",
      "command": "./tools/dexrelay-status.sh",
      "cwd": ".",
      "executionMode": "direct-then-codex",
      "timeoutMs": 120000,
      "showInQuickActions": true
    },
    {
      "id": "dexrelay-doctor",
      "title": "Show Runtime Paths",
      "subtitle": "Print the resolved runtime root, admin workspace, and launch-agent paths.",
      "icon": "folder",
      "kind": "shell",
      "command": "./tools/dexrelay-doctor.sh",
      "cwd": ".",
      "executionMode": "direct-then-codex",
      "timeoutMs": 120000,
      "showInQuickActions": true
    },
    {
      "id": "refresh-project-setup",
      "title": "Refresh Project Setup",
      "subtitle": "Regenerate missing project governance and runbooks under the current projects root.",
      "icon": "arrow.triangle.2.circlepath",
      "kind": "shell",
      "command": "./tools/refresh-project-setup.sh",
      "cwd": ".",
      "executionMode": "direct-then-codex",
      "timeoutMs": 1200000,
      "showInQuickActions": true
    },
    {
      "id": "open-health-ui",
      "title": "Open Health UI",
      "subtitle": "Open the local DexRelay health dashboard in the browser.",
      "icon": "safari",
      "kind": "shell",
      "command": "./tools/open-health-ui.sh",
      "cwd": ".",
      "executionMode": "direct-then-codex",
      "timeoutMs": 120000,
      "showInQuickActions": true
    }
  ]
}
EOF
  fi

  if [[ ! -f "$codex_dir/project-governance.json" ]]; then
    cat >"$codex_dir/project-governance.json" <<EOF
{
  "version": 1,
  "projectName": "DexRelay Admin",
  "projectPath": $(python3 - <<'PY' "$ADMIN_PROJECT_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
  "projectType": "admin-workspace",
  "description": "Pinned support workspace for repairing DexRelay setup, project access, and service registration on this Mac.",
  "managedBy": "DexRelay Installer",
  "storage": {
    "mode": "project-local",
    "folder": ".dexrelay",
    "persistsAcrossReinstall": true,
    "rebuildInstruction": "Rerun dexrelay install to restore missing admin tools without modifying the runtime internals directly."
  },
  "backendMode": "none",
  "runbookPath": ".dexrelay/project-runbook.json",
  "governanceRules": {
    "requirePortRegistration": true,
    "preferManagedServices": true,
    "preserveExistingRunbookActions": true,
    "avoidHardcodedTailscaleHosts": true
  },
  "services": [],
  "runtime": {
    "installRoot": $(python3 - <<'PY' "$INSTALL_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
    "projectsRoot": $(python3 - <<'PY' "$DEFAULT_PROJECTS_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
),
    "adminProjectRoot": $(python3 - <<'PY' "$ADMIN_PROJECT_ROOT"
import json, sys
print(json.dumps(sys.argv[1]))
PY
)
  },
  "codexInstructions": [
    "Use this workspace to diagnose DexRelay itself, not to edit runtime internals blindly.",
    "Prefer dexrelay commands, helper APIs, and wrapper tools in ./tools before modifying runtime files.",
    "If repairing a user project, keep its .dexrelay/project-governance.json and .dexrelay/project-runbook.json in sync."
  ]
}
EOF
  fi
}

write_start_script() {
  mkdir -p "$BIN_DIR" "$LOG_DIR"

  cat >"$BIN_DIR/start-bridge.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
export NODE_PATH="$BRIDGE_DIR/node_modules:$LOCAL_PAYLOAD_ROOT/node_modules:\${NODE_PATH:-}"
cd "$BRIDGE_DIR"

NODE_BIN="\$(command -v node)"
CODEX_BIN="\$(command -v codex)"

exec env \
  BRIDGE_HOST="0.0.0.0" \
  BRIDGE_PORT="$BRIDGE_PORT" \
  UPSTREAM_TRANSPORT="stdio" \
  CODEX_BIN="\$CODEX_BIN" \
  CODEX_UPSTREAM_CWD="$DEFAULT_PROJECTS_ROOT" \
  "\$NODE_BIN" "$BRIDGE_DIR/bridge.js"
EOF

  chmod +x "$BIN_DIR/start-bridge.sh"
}

write_helper_start_script() {
  mkdir -p "$BIN_DIR" "$HELPER_LOG_DIR" "$OTA_PUBLIC_ROOT"

  cat >"$BIN_DIR/start-helper.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
cd "$HELPER_DIR"

PYTHON_BIN="\$(command -v python3 || true)"
if [[ -z "\$PYTHON_BIN" ]]; then
  echo "python3 is required for codex relay setup helper" >&2
  exit 1
fi

exec env \
  CODEX_RELAY_ROOT="$INSTALL_ROOT" \
  CODEX_RELAY_SETUP_BASE_URL="$SETUP_BASE_URL" \
  CODEX_RELAY_PROJECTS_ROOT="$DEFAULT_PROJECTS_ROOT" \
  CODEX_RELAY_ADMIN_PROJECT_ROOT="$ADMIN_PROJECT_ROOT" \
  CODEX_RELAY_LABEL="$BRIDGE_LABEL" \
  CODEX_RELAY_BRIDGE_PORT="$BRIDGE_PORT" \
  CODEX_RELAY_ENABLE_QUIC="$ENABLE_QUIC" \
  CODEX_RELAY_QUIC_PORT="$QUIC_GATEWAY_PORT" \
  CODEX_RELAY_HELPER_LABEL="$HELPER_LABEL" \
  CODEX_RELAY_HELPER_PORT="$HELPER_PORT" \
  CODEX_RELAY_OTA_PUBLIC_ROOT="$OTA_PUBLIC_ROOT" \
  CODEX_RELAY_SERVER_PORT="$RELAY_SERVER_PORT" \
  CODEX_RELAY_SERVER_PATH="$RELAY_SERVER_PATH" \
  "\$PYTHON_BIN" "$HELPER_DIR/helper.py"
EOF

  chmod +x "$BIN_DIR/start-helper.sh"
}

write_healthd_start_script() {
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$HEALTH_UI_DIR"

  cat >"$BIN_DIR/start-healthd.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
cd "$INSTALL_ROOT"

PYTHON_BIN="\$(command -v python3 || true)"
if [[ -z "\$PYTHON_BIN" ]]; then
  echo "python3 is required for DexRelay health daemon" >&2
  exit 1
fi

exec env \
  CODEX_RELAY_ROOT="$INSTALL_ROOT" \
  CODEX_RELAY_PROJECTS_ROOT="$DEFAULT_PROJECTS_ROOT" \
  CODEX_RELAY_ADMIN_PROJECT_ROOT="$ADMIN_PROJECT_ROOT" \
  CODEX_RELAY_LABEL="$BRIDGE_LABEL" \
  CODEX_RELAY_BRIDGE_PORT="$BRIDGE_PORT" \
  CODEX_RELAY_ENABLE_QUIC="$ENABLE_QUIC" \
  CODEX_RELAY_QUIC_PORT="$QUIC_GATEWAY_PORT" \
  CODEX_RELAY_HELPER_LABEL="$HELPER_LABEL" \
  CODEX_RELAY_HELPER_PORT="$HELPER_PORT" \
  CODEX_RELAY_HEALTHD_LABEL="$HEALTHD_LABEL" \
  CODEX_HEALTH_PORT="$HEALTH_PORT" \
  CODEX_RELAY_RELAY_SERVER_LABEL="$RELAY_SERVER_LABEL" \
  CODEX_RELAY_RELAY_SERVER_PORT="$RELAY_SERVER_PORT" \
  CODEX_RELAY_RELAY_CONNECTOR_LABEL="$RELAY_CONNECTOR_LABEL" \
  CODEX_RELAY_QUIC_GATEWAY_LABEL="$QUIC_GATEWAY_LABEL" \
  "\$PYTHON_BIN" "$SCRIPTS_DIR/codex-health-daemon.py"
EOF

  chmod +x "$BIN_DIR/start-healthd.sh"
}

write_relay_server_start_script() {
  mkdir -p "$BIN_DIR" "$LOG_DIR"

  cat >"$BIN_DIR/start-relay-server.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
export NODE_PATH="$BRIDGE_DIR/node_modules:$LOCAL_PAYLOAD_ROOT/node_modules:\${NODE_PATH:-}"
cd "$BRIDGE_DIR"

NODE_BIN="\$(command -v node)"

exec env \
  RELAY_SERVER_HOST="0.0.0.0" \
  RELAY_SERVER_PORT="${RELAY_SERVER_PORT}" \
  RELAY_SERVER_PATH="${RELAY_SERVER_PATH}" \
  "\$NODE_BIN" "$BRIDGE_DIR/relay-server.js"
EOF

  chmod +x "$BIN_DIR/start-relay-server.sh"
}

write_relay_connector_start_script() {
  mkdir -p "$BIN_DIR" "$LOG_DIR"

  cat >"$BIN_DIR/start-relay-connector.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
export NODE_PATH="$BRIDGE_DIR/node_modules:$LOCAL_PAYLOAD_ROOT/node_modules:\${NODE_PATH:-}"
cd "$BRIDGE_DIR"

NODE_BIN="\$(command -v node)"
CONNECTOR_ENV_FILE="${RELAY_STATE_DIR}/connector.env"

if [[ ! -f "\$CONNECTOR_ENV_FILE" ]]; then
  echo "relay connector idle: no pairing config at \$CONNECTOR_ENV_FILE" >&2
  exec /bin/sleep 3600
fi

set -a
source "\$CONNECTOR_ENV_FILE"
set +a

exec env \
  RELAY_CONNECTOR_LOCAL_BRIDGE_URL="\${RELAY_CONNECTOR_LOCAL_BRIDGE_URL:-ws://127.0.0.1:${BRIDGE_PORT}}" \
  "\$NODE_BIN" "$BRIDGE_DIR/relay-connector.js"
EOF

  chmod +x "$BIN_DIR/start-relay-connector.sh"
}

write_quic_gateway_start_script() {
  mkdir -p "$BIN_DIR" "$LOG_DIR" "$INSTALL_ROOT/quic"

  cat >"$BIN_DIR/start-quic-gateway.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
cd "$BRIDGE_DIR"

SOURCE="$BRIDGE_DIR/quic-bridge-gateway.swift"
BINARY="$BIN_DIR/quic-bridge-gateway"
IDENTITY_DIR="$INSTALL_ROOT/quic"
IDENTITY_P12="\$IDENTITY_DIR/identity.p12"
IDENTITY_PASSWORD="dexrelay"

mkdir -p "\$IDENTITY_DIR"

if [[ ! -f "\$IDENTITY_P12" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "QUIC gateway idle: openssl is required to create the local identity" >&2
    exec /bin/sleep 3600
  fi
  tmp_dir="\$(mktemp -d "\${TMPDIR:-/tmp}/dexrelay-quic-identity.XXXXXX")"
  trap 'rm -rf "\$tmp_dir"' EXIT
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=DexRelay QUIC" \
    -keyout "\$tmp_dir/key.pem" \
    -out "\$tmp_dir/cert.pem" >/dev/null 2>&1
  openssl pkcs12 -export \
    -out "\$IDENTITY_P12" \
    -inkey "\$tmp_dir/key.pem" \
    -in "\$tmp_dir/cert.pem" \
    -passout "pass:\$IDENTITY_PASSWORD" >/dev/null 2>&1
  chmod 600 "\$IDENTITY_P12"
fi

if [[ ! -x "\$BINARY" || "\$SOURCE" -nt "\$BINARY" ]]; then
  if command -v swiftc >/dev/null 2>&1; then
    swiftc "\$SOURCE" -o "\$BINARY"
  else
    echo "QUIC gateway idle: swiftc is not available" >&2
    exec /bin/sleep 3600
  fi
fi

exec env \
  DEXRELAY_QUIC_PORT="${QUIC_GATEWAY_PORT}" \
  DEXRELAY_QUIC_BRIDGE_URL="ws://127.0.0.1:${BRIDGE_PORT}" \
  DEXRELAY_QUIC_IDENTITY_P12="\$IDENTITY_P12" \
  DEXRELAY_QUIC_IDENTITY_PASSWORD="\$IDENTITY_PASSWORD" \
  "\$BINARY"
EOF

  chmod +x "$BIN_DIR/start-quic-gateway.sh"
}

write_watchdog_start_script() {
  mkdir -p "$BIN_DIR" "$HELPER_LOG_DIR"

  cat >"$BIN_DIR/start-watchdog.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"

BRIDGE_LABEL="$BRIDGE_LABEL"
BRIDGE_PLIST="$BRIDGE_PLIST"
HELPER_LABEL="$HELPER_LABEL"
HELPER_PLIST="$HELPER_PLIST"
HEALTHD_LABEL="$HEALTHD_LABEL"
HEALTHD_PLIST="$HEALTHD_PLIST"
RELAY_SERVER_LABEL="$RELAY_SERVER_LABEL"
RELAY_SERVER_PLIST="$RELAY_SERVER_PLIST"
RELAY_CONNECTOR_LABEL="$RELAY_CONNECTOR_LABEL"
RELAY_CONNECTOR_PLIST="$RELAY_CONNECTOR_PLIST"
QUIC_GATEWAY_LABEL="$QUIC_GATEWAY_LABEL"
QUIC_GATEWAY_PLIST="$QUIC_GATEWAY_PLIST"
ENABLE_QUIC="$ENABLE_QUIC"
RELAY_STATE_DIR="$RELAY_STATE_DIR"
BRIDGE_PORT="$BRIDGE_PORT"
HELPER_PORT="$HELPER_PORT"
HEALTH_PORT="$HEALTH_PORT"
RELAY_SERVER_PORT="$RELAY_SERVER_PORT"
QUIC_GATEWAY_PORT="$QUIC_GATEWAY_PORT"
INSTALL_SCRIPT_PATH="$SELF_INSTALL_SCRIPT"
WATCHDOG_INTERVAL_SECONDS=5
MAX_FAILED_CYCLES=3
failed_cycles=0

resolve_tailscale_cli() {
  for candidate in "/Applications/Tailscale.app/Contents/MacOS/Tailscale" "/opt/homebrew/bin/tailscale" "/usr/local/bin/tailscale"; do
    [[ -x "\$candidate" ]] && {
      printf '%s\n' "\$candidate"
      return 0
    }
  done
  command -v tailscale >/dev/null 2>&1 && command -v tailscale && return 0
  return 1
}

restart_agent() {
  local label="\$1"
  local plist="\$2"
  local uid_num gui_domain user_domain
  [[ -f "\$plist" ]] || return 1
  uid_num="\$(id -u)"
  gui_domain="gui/\$uid_num"
  user_domain="user/\$uid_num"
  launchctl bootout "\$gui_domain/\$label" >/dev/null 2>&1 || true
  launchctl bootout "\$user_domain/\$label" >/dev/null 2>&1 || true
  launchctl bootstrap "\$gui_domain" "\$plist" >/dev/null 2>&1 || launchctl bootstrap "\$user_domain" "\$plist" >/dev/null 2>&1 || true
  launchctl enable "\$gui_domain/\$label" >/dev/null 2>&1 || launchctl enable "\$user_domain/\$label" >/dev/null 2>&1 || true
}

ensure_tailscale() {
  local tailscale_cli
  tailscale_cli="\$(resolve_tailscale_cli || true)"
  if [[ -n "\$tailscale_cli" ]]; then
    if ! "\$tailscale_cli" status --json >/dev/null 2>&1; then
      /usr/bin/open -g -a Tailscale >/dev/null 2>&1 || true
      "\$tailscale_cli" up >/dev/null 2>&1 || true
    fi
  fi
}

helper_reports_bridge_ready() {
  local payload
  payload="\$(curl -fsS --max-time 2 "http://127.0.0.1:\$HELPER_PORT/api/helper/status" 2>/dev/null || true)"
  [[ -n "\$payload" ]] || return 1
  printf '%s' "\$payload" | grep -q '"bridgeReachable": true'
}

repair_runtime() {
  [[ -x "\$INSTALL_SCRIPT_PATH" ]] || return 1
  env \
    CODEX_RELAY_ROOT="$INSTALL_ROOT" \
    CODEX_RELAY_SETUP_BASE_URL="$SETUP_BASE_URL" \
    CODEX_RELAY_PROJECTS_ROOT="$DEFAULT_PROJECTS_ROOT" \
    CODEX_RELAY_ADMIN_PROJECT_ROOT="$ADMIN_PROJECT_ROOT" \
    CODEX_RELAY_LABEL="$BRIDGE_LABEL" \
    CODEX_RELAY_BRIDGE_PORT="$BRIDGE_PORT" \
    CODEX_RELAY_ENABLE_QUIC="$ENABLE_QUIC" \
    CODEX_RELAY_QUIC_PORT="$QUIC_GATEWAY_PORT" \
    CODEX_RELAY_HELPER_LABEL="$HELPER_LABEL" \
    CODEX_RELAY_HELPER_PORT="$HELPER_PORT" \
    CODEX_RELAY_HEALTHD_LABEL="$HEALTHD_LABEL" \
    CODEX_HEALTH_PORT="$HEALTH_PORT" \
    CODEX_RELAY_SERVER_PORT="$RELAY_SERVER_PORT" \
    CODEX_RELAY_SERVER_PATH="$RELAY_SERVER_PATH" \
    CODEX_RELAY_KEEP_AWAKE="$KEEP_AWAKE" \
    /bin/bash "\$INSTALL_SCRIPT_PATH" >/dev/null 2>&1 || true
}

while true; do
  unhealthy=0

  ensure_tailscale

  if ! lsof -nP -iTCP:"\$HELPER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    restart_agent "\$HELPER_LABEL" "\$HELPER_PLIST"
    unhealthy=1
  fi

  if ! lsof -nP -iTCP:"\$HEALTH_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    restart_agent "\$HEALTHD_LABEL" "\$HEALTHD_PLIST"
    unhealthy=1
  fi

  if ! lsof -nP -iTCP:"\$BRIDGE_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    restart_agent "\$BRIDGE_LABEL" "\$BRIDGE_PLIST"
    unhealthy=1
  fi

  if ! helper_reports_bridge_ready; then
    restart_agent "\$BRIDGE_LABEL" "\$BRIDGE_PLIST"
    unhealthy=1
  fi

  if ! lsof -nP -iTCP:"\$RELAY_SERVER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    restart_agent "\$RELAY_SERVER_LABEL" "\$RELAY_SERVER_PLIST"
    unhealthy=1
  fi

  case "\$(printf '%s' "\$ENABLE_QUIC" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      if ! lsof -nP -iUDP:"\$QUIC_GATEWAY_PORT" >/dev/null 2>&1; then
        restart_agent "\$QUIC_GATEWAY_LABEL" "\$QUIC_GATEWAY_PLIST"
        unhealthy=1
      fi
      ;;
  esac

  if [[ -f "\$RELAY_STATE_DIR/connector.env" ]] && ! launchctl print "gui/\$(id -u)/\$RELAY_CONNECTOR_LABEL" >/dev/null 2>&1; then
    restart_agent "\$RELAY_CONNECTOR_LABEL" "\$RELAY_CONNECTOR_PLIST"
    unhealthy=1
  fi

  if (( unhealthy )); then
    failed_cycles=\$((failed_cycles + 1))
  else
    failed_cycles=0
  fi

  if (( failed_cycles >= MAX_FAILED_CYCLES )); then
    repair_runtime
    failed_cycles=0
  fi

  sleep "\$WATCHDOG_INTERVAL_SECONDS"
done
EOF

  chmod +x "$BIN_DIR/start-watchdog.sh"
}

write_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR"

  cat >"$BRIDGE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BRIDGE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-bridge.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/bridge.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$BRIDGE_PLIST"
}

write_helper_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR"

  cat >"$HELPER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HELPER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-helper.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$HELPER_LOG_DIR/helper.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HELPER_LOG_DIR/helper.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$HELPER_PLIST"
}

write_healthd_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  cat >"$HEALTHD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$HEALTHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-healthd.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/healthd.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/healthd.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$HEALTHD_PLIST"
}

write_relay_server_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  cat >"$RELAY_SERVER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$RELAY_SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-relay-server.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/relay-server.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/relay-server.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$RELAY_SERVER_PLIST"
}

write_relay_connector_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  cat >"$RELAY_CONNECTOR_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$RELAY_CONNECTOR_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-relay-connector.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/relay-connector.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/relay-connector.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$RELAY_CONNECTOR_PLIST"
}

write_quic_gateway_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  cat >"$QUIC_GATEWAY_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$QUIC_GATEWAY_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-quic-gateway.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/quic-gateway.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/quic-gateway.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$QUIC_GATEWAY_PLIST"
}

write_watchdog_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$HELPER_LOG_DIR"

  cat >"$WATCHDOG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$WATCHDOG_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/start-watchdog.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>45</integer>
  <key>StandardOutPath</key>
  <string>$HELPER_LOG_DIR/watchdog.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HELPER_LOG_DIR/watchdog.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$WATCHDOG_PLIST"
}

start_launch_agent() {
  local label="$1"
  local plist="$2"
  local uid_num gui_domain user_domain
  uid_num="$(id -u)"
  gui_domain="gui/$uid_num"
  user_domain="user/$uid_num"

  launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
  launchctl bootout "$user_domain/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$gui_domain" "$plist" >/dev/null 2>&1 \
    || launchctl bootstrap "$user_domain" "$plist" >/dev/null 2>&1 \
    || true
  launchctl enable "$gui_domain/$label" >/dev/null 2>&1 \
    || launchctl enable "$user_domain/$label" >/dev/null 2>&1 \
    || true
}

start_helper_launch_agent() {
  local uid_num gui_domain user_domain
  uid_num="$(id -u)"
  gui_domain="gui/$uid_num"
  user_domain="user/$uid_num"

  launchctl bootout "$gui_domain/$HELPER_LABEL" >/dev/null 2>&1 || true
  launchctl bootout "$user_domain/$HELPER_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "$gui_domain" "$HELPER_PLIST" >/dev/null 2>&1 \
    || launchctl bootstrap "$user_domain" "$HELPER_PLIST" >/dev/null 2>&1 \
    || true
  launchctl enable "$gui_domain/$HELPER_LABEL" >/dev/null 2>&1 \
    || launchctl enable "$user_domain/$HELPER_LABEL" >/dev/null 2>&1 \
    || true
}

launch_agent_loaded() {
  local label="$1"
  local uid_num gui_domain user_domain
  uid_num="$(id -u)"
  gui_domain="gui/$uid_num"
  user_domain="user/$uid_num"

  launchctl print "$gui_domain/$label" >/dev/null 2>&1 \
    || launchctl print "$user_domain/$label" >/dev/null 2>&1
}

port_listening() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

helper_status_json() {
  curl -fsS --max-time 3 "http://127.0.0.1:${HELPER_PORT}/api/helper/status" 2>/dev/null || true
}

helper_bridge_ready() {
  local payload="$1"
  [[ -n "$payload" ]] || return 1
  printf '%s' "$payload" | grep -q '"bridgeReachable":[[:space:]]*true'
}

wait_for_runtime_ready() {
  local attempts="${1:-20}"
  local helper_json=""

  while (( attempts > 0 )); do
    helper_json="$(helper_status_json)"

    if launch_agent_loaded "$BRIDGE_LABEL" \
      && launch_agent_loaded "$HELPER_LABEL" \
      && launch_agent_loaded "$RELAY_SERVER_LABEL" \
      && port_listening "$BRIDGE_PORT" \
      && port_listening "$HELPER_PORT" \
      && port_listening "$RELAY_SERVER_PORT" \
      && helper_bridge_ready "$helper_json"; then
      return 0
    fi

    sleep 1
    attempts=$((attempts - 1))
  done

  return 1
}

write_awake_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"

  if [[ "$KEEP_AWAKE" != "1" ]]; then
    rm -f "$AWAKE_PLIST"
    return 0
  fi

  cat >"$AWAKE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AWAKE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-dimsu</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/awake.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/awake.err.log</string>
</dict>
</plist>
EOF

  chmod 644 "$AWAKE_PLIST"
}

stop_launch_agent() {
  local label="$1"
  local uid_num gui_domain user_domain
  uid_num="$(id -u)"
  gui_domain="gui/$uid_num"
  user_domain="user/$uid_num"

  launchctl bootout "$gui_domain/$label" >/dev/null 2>&1 || true
  launchctl bootout "$user_domain/$label" >/dev/null 2>&1 || true
}

maybe_start_relay_connector_launch_agent() {
  if [[ -f "$RELAY_STATE_DIR/connector.env" ]]; then
    start_launch_agent "$RELAY_CONNECTOR_LABEL" "$RELAY_CONNECTOR_PLIST"
  else
    stop_launch_agent "$RELAY_CONNECTOR_LABEL"
  fi
}

show_next_steps() {
  local payload_version="unknown"
  if [[ -f "$LOCAL_PACKAGE_SOURCE" ]]; then
    payload_version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$LOCAL_PACKAGE_SOURCE" | head -n 1)"
  elif [[ -f "$SCRIPTS_DIR/../package.json" ]]; then
    payload_version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPTS_DIR/../package.json" | head -n 1)"
  fi
  payload_version="${payload_version:-$DEXRELAY_PAYLOAD_VERSION}"

  log "Setup complete"
  printf "\nDexRelay %s is ready on this Mac.\n" "$payload_version"
  printf "\nNext steps:\n"
  printf "1. Open the DexRelay iOS app. It should automatically find this Mac on local Wi-Fi.\n"
  printf "2. If it does not appear, tap the Mac/Apple connect icon and use optional QR pairing.\n"
  printf "3. Optional QR: run dexrelay pair, then scan the code from the app.\n"
  printf "4. Optional remote access: install Tailscale on your Mac and iPhone for away-from-Wi-Fi use.\n"
  printf "\nUseful commands:\n"
  printf -- "- dexrelay version             Show the installed DexRelay CLI version\n"
  printf -- "- dexrelay status              Check bridge, helper, Tailscale, and wake health\n"
  printf -- "- dexrelay pair                Show an optional QR code for iPhone pairing\n"
  printf -- "- dexrelay relay-pair          Prepare relay bootstrap and show relay QR\n"
  printf -- "- dexrelay repair              Repair the DexRelay runtime if services drift\n"
  printf -- "- dexrelay wake on|off|status  Keep this Mac awake for remote sessions\n"
  printf -- "- dexrelay codex-fast report   Find slow/heavy Codex local state\n"
  printf -- "- dexrelay codex-fast apply    Back up and safely archive old Codex state\n"
  printf -- "- dexrelay doctor              Show install paths and runtime metadata\n"
  printf "\nInstalled files:\n"
  printf -- "- Runtime root: %s\n" "$INSTALL_ROOT"
  printf -- "- Admin workspace: %s\n" "$ADMIN_PROJECT_ROOT"
  printf -- "- LaunchAgent: %s\n" "$BRIDGE_PLIST"
  printf -- "- Logs: %s\n" "$LOG_DIR"
  printf -- "- Setup helper: http://127.0.0.1:%s/api/helper/status\n" "$HELPER_PORT"
  printf -- "- Health daemon: http://127.0.0.1:%s/api/health\n" "$HEALTH_PORT"
  printf -- "- Watchdog: %s\n" "$WATCHDOG_LABEL"
  if [[ "$KEEP_AWAKE" == "1" ]]; then
    printf -- "- Keep-awake: enabled via %s\n" "$AWAKE_LABEL"
  else
    printf -- "- Keep-awake: disabled\n"
  fi
}

main() {
  phase "1/4: checking prerequisites"
  require_macos
  ensure_homebrew
  load_brew_env
  ensure_tailscale_installed
  ensure_tailscale_connected
  ensure_tailscale_serve_enabled
  ensure_formula node
  ensure_formula python
  ensure_formula jq
  ensure_codex

  phase "2/4: installing DexRelay runtime files"
  install_bridge_assets
  install_helper_assets
  install_runtime_scripts
  migrate_project_state
  write_runtime_manifest
  scaffold_admin_project
  write_start_script
  write_helper_start_script
  write_healthd_start_script
  write_relay_server_start_script
  write_relay_connector_start_script
  if quic_enabled; then
    write_quic_gateway_start_script
  fi
  write_watchdog_start_script
  write_launch_agent
  write_helper_launch_agent
  write_healthd_launch_agent
  write_relay_server_launch_agent
  write_relay_connector_launch_agent
  if quic_enabled; then
    write_quic_gateway_launch_agent
  else
    rm -f "$QUIC_GATEWAY_PLIST"
  fi
  write_watchdog_launch_agent
  write_awake_launch_agent

  phase "3/4: starting background services"
  start_helper_launch_agent
  start_launch_agent "$HEALTHD_LABEL" "$HEALTHD_PLIST"
  start_launch_agent "$BRIDGE_LABEL" "$BRIDGE_PLIST"
  if quic_enabled; then
    start_launch_agent "$QUIC_GATEWAY_LABEL" "$QUIC_GATEWAY_PLIST"
  else
    stop_launch_agent "$QUIC_GATEWAY_LABEL"
  fi
  start_launch_agent "$RELAY_SERVER_LABEL" "$RELAY_SERVER_PLIST"
  maybe_start_relay_connector_launch_agent
  start_launch_agent "$WATCHDOG_LABEL" "$WATCHDOG_PLIST"
  if [[ "$KEEP_AWAKE" == "1" ]]; then
    start_launch_agent "$AWAKE_LABEL" "$AWAKE_PLIST"
  else
    stop_launch_agent "$AWAKE_LABEL"
  fi

  phase "4/4: waiting for DexRelay to become ready"
  if ! wait_for_runtime_ready 20; then
    fail "DexRelay runtime did not become healthy after install. Run \`dexrelay status\` for details."
  fi
  show_next_steps
}

main "$@"
