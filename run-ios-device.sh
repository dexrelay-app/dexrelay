#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./xcode-devdir.sh
source "$SCRIPT_DIR/xcode-devdir.sh"
ensure_xcode_developer_dir

usage() {
  cat <<'EOF'
Usage:
  run-ios-device.sh --project <path/to.xcodeproj> --scheme <Scheme> --device-id <XcodeDeviceID> [--derived-data <path>] [--configuration <Debug|Release>] [--bundle-id <id>] [--team-id <TEAMID>]

Example:
  ./scripts/run-ios-device.sh \
    --project CodexRemote.xcodeproj \
    --scheme CodexRemote \
    --device-id 00008130-001C71623CF0001C

Notes:
  - Builds for a physical iPhone, installs, then launches using xcrun devicectl.
  - If --team-id is omitted, the script tries the project settings first, then local provisioning profiles, then a unique Apple Development identity.
  - If --bundle-id is omitted, this script infers it from the built app Info.plist.
EOF
}

PROJECT=""
SCHEME=""
DEVICE_ID=""
DERIVED_DATA=""
CONFIGURATION="Debug"
BUNDLE_ID=""
TEAM_ID=""
SPM_CACHE_DIR="$HOME/.codex/spm-cache"
AUTO_DERIVED_DATA=0
RUN_STATUS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"; shift 2 ;;
    --scheme)
      SCHEME="${2:-}"; shift 2 ;;
    --device-id)
      DEVICE_ID="${2:-}"; shift 2 ;;
    --derived-data)
      DERIVED_DATA="${2:-}"; shift 2 ;;
    --configuration)
      CONFIGURATION="${2:-}"; shift 2 ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"; shift 2 ;;
    --team-id)
      TEAM_ID="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$PROJECT" || -z "$SCHEME" || -z "$DEVICE_ID" ]]; then
  usage
  exit 1
fi

if [[ -z "$DERIVED_DATA" ]]; then
  DERIVED_DATA="$(mktemp -d /tmp/CodexDeviceBuild.XXXXXX)"
  AUTO_DERIVED_DATA=1
fi

cleanup() {
  if [[ "$AUTO_DERIVED_DATA" -eq 1 && "$RUN_STATUS" -eq 0 ]]; then
    rm -rf "$DERIVED_DATA"
  elif [[ "$AUTO_DERIVED_DATA" -eq 1 ]]; then
    echo "==> Preserving failed derived data at $DERIVED_DATA" >&2
  fi
}

trap cleanup EXIT

echo "==> Building '$SCHEME' for device '$DEVICE_ID'"
echo "==> Using derived data '$DERIVED_DATA'"
mkdir -p "$SPM_CACHE_DIR"

SIGNING_CONTEXT_JSON=""
PROJECT_HAS_TEAM=0
if SIGNING_CONTEXT_JSON="$(detect_xcode_signing_context_json "$PROJECT" "$SCHEME" "$CONFIGURATION" 2>/dev/null)"; then
  if [[ -n "$SIGNING_CONTEXT_JSON" ]]; then
    PROJECT_HAS_TEAM="$(python3 - <<'PY' "$SIGNING_CONTEXT_JSON"
import json
import sys

data = json.loads(sys.argv[1])
print("1" if data.get("projectTeams") else "0")
PY
)"

    if [[ -z "$TEAM_ID" ]]; then
      TEAM_ID="$(python3 - <<'PY' "$SIGNING_CONTEXT_JSON"
import json
import sys

data = json.loads(sys.argv[1])
print((data.get("teamID") or "").strip())
PY
)"
    fi

    if [[ -n "$TEAM_ID" ]]; then
      TEAM_SOURCE="$(python3 - <<'PY' "$SIGNING_CONTEXT_JSON"
import json
import sys

data = json.loads(sys.argv[1])
print((data.get("source") or "project_build_settings").strip())
PY
)"
      echo "==> Using development team $TEAM_ID ($TEAM_SOURCE)"
    fi
  fi
fi

if [[ -z "$TEAM_ID" && "$PROJECT_HAS_TEAM" != "1" ]]; then
  DIAGNOSTIC_MESSAGE="$(python3 - <<'PY' "$SIGNING_CONTEXT_JSON"
import json
import sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
if not raw:
    print("Could not infer a development team for this project.")
    raise SystemExit(0)

data = json.loads(raw)
reason = (data.get("reason") or "").strip()
candidates = [str(item).strip() for item in (data.get("candidateTeams") or []) if str(item).strip()]
message = reason or "Could not infer a development team for this project."
if candidates:
    message += " Candidate teams: " + ", ".join(candidates)
print(message)
PY
)"
  echo "$DIAGNOSTIC_MESSAGE" >&2
  echo "Add a DEVELOPMENT_TEAM to the Xcode project, or sign once in Xcode so automatic signing can reuse that team." >&2
  exit 1
fi

echo "==> Resolving Swift packages (shared cache)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$SPM_CACHE_DIR" \
  -skipPackageUpdates \
  -resolvePackageDependencies

APP_PATH="$DERIVED_DATA/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"

BUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination "id=$DEVICE_ID"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED_DATA"
  -disableAutomaticPackageResolution
  -clonedSourcePackagesDirPath "$SPM_CACHE_DIR"
  -skipPackageUpdates
  -allowProvisioningUpdates
  -allowProvisioningDeviceRegistration
  COMPILER_INDEX_STORE_ENABLE=NO
)

if [[ -n "$TEAM_ID" ]]; then
  BUILD_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

xcodebuild "${BUILD_ARGS[@]}" build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at: $APP_PATH" >&2
  exit 1
fi

if [[ -z "$BUNDLE_ID" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
fi

if [[ -z "$BUNDLE_ID" ]]; then
  echo "Could not determine bundle identifier." >&2
  exit 1
fi

echo "==> Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "==> Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "==> Done"
RUN_STATUS=0
