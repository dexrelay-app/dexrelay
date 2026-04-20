#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=./xcode-devdir.sh
source "$SCRIPT_DIR/xcode-devdir.sh"
ensure_xcode_developer_dir

PROJECT="CodexRemote.xcodeproj"
SCHEME="CodexRemote"
CONFIGURATION="Debug"
TITLE="DexRelay Debug"
DEVICE_ID=""
SPM_CACHE_DIR="$HOME/.codex/spm-cache"

usage() {
  cat <<'EOF'
Usage:
  run-ios-on-phone.sh [--project <xcodeproj>] [--scheme <name>] [--configuration <Debug|Release>] [--device-id <id>]

Behavior:
  1. Build/install/launch on connected iPhone via devicectl.
  2. If no connected device or install path fails, fallback to OTA debug build/install link flow.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"; shift 2 ;;
    --scheme)
      SCHEME="${2:-}"; shift 2 ;;
    --configuration)
      CONFIGURATION="${2:-}"; shift 2 ;;
    --device-id)
      DEVICE_ID="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

detect_connected_device() {
  local tmp
  tmp="$(mktemp)"
  if ! xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  python3 - <<'PY' "$tmp"
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
devices = data.get("result", {}).get("devices", [])
for d in devices:
    cp = d.get("connectionProperties", {}) or {}
    if cp.get("tunnelState") == "connected":
        ident = (d.get("identifier") or "").strip()
        if ident:
            print(ident)
            break
PY
  rm -f "$tmp"
}

fallback_to_ota() {
  echo "==> Falling back to OTA debug install flow"
  "$SCRIPT_DIR/publish-ios-adhoc-ota.sh" \
    --project "$PROJECT" \
    --scheme "$SCHEME" \
    --method debugging \
    --configuration "$CONFIGURATION" \
    --title "$TITLE" \
    --allow-provisioning-updates
}

mkdir -p "$SPM_CACHE_DIR"
cd "$REPO_ROOT"

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(detect_connected_device || true)"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "No connected iPhone detected via Xcode device services."
  fallback_to_ota
  exit 0
fi

if "$SCRIPT_DIR/run-ios-device.sh" \
  --project "$PROJECT" \
  --scheme "$SCHEME" \
  --device-id "$DEVICE_ID" \
  --configuration "$CONFIGURATION"; then
  echo "==> Run on iPhone completed"
  exit 0
fi

echo "Direct device run failed for device: $DEVICE_ID"
fallback_to_ota
