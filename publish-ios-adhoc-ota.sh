#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./xcode-devdir.sh
source "$SCRIPT_DIR/xcode-devdir.sh"
ensure_xcode_developer_dir

usage() {
  cat <<'EOF'
Usage:
  publish-ios-adhoc-ota.sh \
    --project <path/to.xcodeproj> \
    --scheme <Scheme> \
    [--method debugging|release-testing] \
    [--configuration Release] \
    [--team-id <TEAMID>] \
    [--title <Display Name>] \
    [--slug <url-fragment>] \
    [--output-root <dir>] \
    [--public-base-url <https-url>] \
    [--skip-tailscale-serve] \
    [--allow-provisioning-updates]

Example:
  ./scripts/publish-ios-adhoc-ota.sh \
    --project CodexRemote.xcodeproj \
    --scheme CodexRemote \
    --title "Codex iPhone to Mac Relay"

What it does:
  1. Archives the iOS app.
  2. Exports a release-testing (ad hoc style) IPA and manifest.plist.
  3. Copies OTA artifacts to DexRelay helper's persistent OTA public directory.
  4. Exposes that project path over Tailscale HTTPS using `tailscale serve --set-path`.

Notes:
  - `--method debugging` uses development-style registered-device provisioning and is the default.
  - `--method release-testing` is closer to true ad hoc distribution, but requires a matching distribution profile.
  - The generated install link is intended for iPhone Safari:
      itms-services://?action=download-manifest&url=<manifest.plist HTTPS URL>
EOF
}

PROJECT=""
SCHEME=""
METHOD="debugging"
CONFIGURATION=""
TEAM_ID=""
TITLE=""
SLUG=""
OUTPUT_ROOT="${TMPDIR:-/tmp}/codex-ota"
DERIVED_DATA_ROOT="${TMPDIR:-/tmp}/codex-ota-derived-data"
HELPER_PORT="${CODEX_RELAY_HELPER_PORT:-4616}"
OTA_PUBLIC_ROOT="${CODEX_RELAY_OTA_PUBLIC_ROOT:-$HOME/Library/Application Support/CodexRelayHelper/ota/public}"
PUBLIC_BASE_URL=""
ALLOW_PROVISIONING_UPDATES=0
SKIP_TAILSCALE_SERVE=0
SPM_CACHE_DIR="$HOME/.codex/spm-cache"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"; shift 2 ;;
    --scheme)
      SCHEME="${2:-}"; shift 2 ;;
    --configuration)
      CONFIGURATION="${2:-}"; shift 2 ;;
    --method)
      METHOD="${2:-}"; shift 2 ;;
    --team-id)
      TEAM_ID="${2:-}"; shift 2 ;;
    --title)
      TITLE="${2:-}"; shift 2 ;;
    --slug)
      SLUG="${2:-}"; shift 2 ;;
    --output-root)
      OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --public-base-url)
      PUBLIC_BASE_URL="${2:-}"; shift 2 ;;
    --skip-tailscale-serve)
      SKIP_TAILSCALE_SERVE=1; shift ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "$PROJECT" || -z "$SCHEME" ]]; then
  usage
  exit 1
fi

if [[ "$METHOD" != "debugging" && "$METHOD" != "release-testing" ]]; then
  echo "Unsupported --method: $METHOD" >&2
  exit 1
fi

if [[ -z "$CONFIGURATION" ]]; then
  if [[ "$METHOD" == "debugging" ]]; then
    CONFIGURATION="Debug"
  else
    CONFIGURATION="Release"
  fi
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd xcodebuild
need_cmd python3
need_cmd security
need_cmd curl
need_cmd /Applications/Tailscale.app/Contents/MacOS/tailscale

if [[ -z "$TITLE" ]]; then
  TITLE="$SCHEME"
fi

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

if [[ -z "$SLUG" ]]; then
  SLUG="$(slugify "$SCHEME")"
fi

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

PUBLIC_ROOT="$OTA_PUBLIC_ROOT"
PUBLIC_PROJECT_ROOT="$PUBLIC_ROOT/$SLUG"
PUBLIC_RELEASES_ROOT="$PUBLIC_PROJECT_ROOT/releases"
PUBLIC_LATEST_ROOT="$PUBLIC_PROJECT_ROOT/latest"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DERIVED_DATA_ROOT"
mkdir -p "$SPM_CACHE_DIR"
DERIVED_DATA="$DERIVED_DATA_ROOT/$SLUG"
if [[ ! -d "$DERIVED_DATA" ]]; then
  LEGACY_DERIVED_DATA="$(find "$DERIVED_DATA_ROOT" -maxdepth 1 -type d -name "$SLUG-*" -print 2>/dev/null | LC_ALL=C sort | tail -n 1)"
  if [[ -n "$LEGACY_DERIVED_DATA" && -d "$LEGACY_DERIVED_DATA" ]]; then
    mv "$LEGACY_DERIVED_DATA" "$DERIVED_DATA" 2>/dev/null || mkdir -p "$DERIVED_DATA"
  else
    mkdir -p "$DERIVED_DATA"
  fi
fi
RELEASE_DIR="$OUTPUT_ROOT/$SLUG-$TIMESTAMP"
ARCHIVE_PATH="$RELEASE_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$RELEASE_DIR/export"
EXPORT_OPTIONS_PLIST="$RELEASE_DIR/ExportOptions.plist"
mkdir -p "$EXPORT_PATH" "$PUBLIC_ROOT" "$PUBLIC_RELEASES_ROOT" "$PUBLIC_LATEST_ROOT"

if [[ -z "$PUBLIC_BASE_URL" ]]; then
  TS_STATUS_JSON="$(/Applications/Tailscale.app/Contents/MacOS/tailscale status --json)"
  DNS_NAME="$(TS_STATUS_JSON="$TS_STATUS_JSON" python3 - <<'PY'
import json, os
data = json.loads(os.environ["TS_STATUS_JSON"])
name = (data.get("Self", {}) or {}).get("DNSName", "")
print(name.rstrip("."))
PY
)"
  if [[ -z "$DNS_NAME" ]]; then
    echo "Could not determine Tailscale DNS name. Pass --public-base-url explicitly." >&2
    exit 1
  fi
  PUBLIC_BASE_URL="https://$DNS_NAME"
fi

APP_URL="$PUBLIC_BASE_URL/$SLUG/latest/$SLUG.ipa"
MANIFEST_URL="$PUBLIC_BASE_URL/$SLUG/latest/manifest.plist"
DISPLAY_IMAGE_URL="$PUBLIC_BASE_URL/$SLUG/latest/display.png"
FULLSIZE_IMAGE_URL="$PUBLIC_BASE_URL/$SLUG/latest/fullsize.png"
LOCAL_MANIFEST_URL="http://127.0.0.1:$HELPER_PORT/$SLUG/latest/manifest.plist"
INSTALL_URL="itms-services://?action=download-manifest&url=$MANIFEST_URL"
PROJECT_PAGE_URL="$PUBLIC_BASE_URL/$SLUG/"
RELEASE_APP_URL="$PUBLIC_BASE_URL/$SLUG/releases/$TIMESTAMP/$SLUG.ipa"
RELEASE_MANIFEST_URL="$PUBLIC_BASE_URL/$SLUG/releases/$TIMESTAMP/manifest.plist"
EXPORT_METADATA_JSON="$RELEASE_DIR/export-signing.json"

detect_export_signing_metadata() {
  python3 - <<'PY' "$ARCHIVE_PATH" "$METHOD"
import json
import plistlib
import subprocess
import sys
from pathlib import Path

archive_path = Path(sys.argv[1])
method = sys.argv[2]
apps_dir = archive_path / "Products" / "Applications"

def parse_mobileprovision(path: Path):
    try:
        raw = subprocess.check_output(
            ["security", "cms", "-D", "-i", str(path)],
            stderr=subprocess.DEVNULL,
        )
        return plistlib.loads(raw)
    except Exception:
        return None

def bundle_paths():
    results = []
    if not apps_dir.exists():
        return results
    for app in sorted(apps_dir.glob("*.app")):
        results.append(app)
        for subdir in ("PlugIns", "Extensions"):
            folder = app / subdir
            if folder.exists():
                results.extend(sorted(folder.glob("*.appex")))
    return results

def app_id_matches(pattern: str, bundle_id: str) -> bool:
    if pattern == bundle_id:
        return True
    if pattern.endswith("*"):
        return bundle_id.startswith(pattern[:-1])
    return False

def local_profile_dirs():
    home = Path.home()
    return [
        home / "Library" / "MobileDevice" / "Provisioning Profiles",
        home / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles",
        home / "Library" / "Developer" / "Xcode" / "Provisioning Profiles",
    ]

target_bundles = []
team_id = ""
provisioning_profiles = {}

for bundle_path in bundle_paths():
    info_path = bundle_path / "Info.plist"
    if not info_path.exists():
        continue
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except Exception:
        continue
    bundle_id = (info.get("CFBundleIdentifier") or "").strip()
    if not bundle_id:
        continue
    if bundle_id not in target_bundles:
        target_bundles.append(bundle_id)
    profile_path = bundle_path / "embedded.mobileprovision"
    if not profile_path.exists():
        continue
    profile = parse_mobileprovision(profile_path)
    if not profile:
        continue
    name = (profile.get("Name") or "").strip()
    teams = profile.get("TeamIdentifier") or []
    if not team_id and teams:
        team_id = str(teams[0]).strip()
    if name:
        provisioning_profiles[bundle_id] = name

need_debug = method == "debugging"
if target_bundles and len(provisioning_profiles) < len(target_bundles):
    candidates = []
    for directory in local_profile_dirs():
        if not directory.exists():
            continue
        for pattern in ("*.mobileprovision", "*.provisionprofile"):
            for path in directory.glob(pattern):
                profile = parse_mobileprovision(path)
                if not profile:
                    continue
                teams = profile.get("TeamIdentifier") or []
                current_team = str(teams[0]).strip() if teams else ""
                entitlements = profile.get("Entitlements") or {}
                app_identifier = str(entitlements.get("application-identifier") or "").strip()
                if "." not in app_identifier:
                    continue
                _, _, app_id_pattern = app_identifier.partition(".")
                get_task_allow = bool(entitlements.get("get-task-allow"))
                provisioned_devices = profile.get("ProvisionedDevices") or []
                name = str(profile.get("Name") or "").strip()
                if not name:
                    continue
                candidates.append(
                    {
                        "team_id": current_team,
                        "name": name,
                        "pattern": app_id_pattern,
                        "get_task_allow": get_task_allow,
                        "has_devices": bool(provisioned_devices),
                    }
                )

    for bundle_id in target_bundles:
        matches = [c for c in candidates if app_id_matches(c["pattern"], bundle_id)]
        if team_id:
            team_matches = [c for c in matches if c["team_id"] == team_id]
            if team_matches:
                matches = team_matches
        if need_debug:
            matches = [c for c in matches if c["get_task_allow"] and c["has_devices"]]
        else:
            matches = [c for c in matches if (not c["get_task_allow"]) and c["has_devices"]]
        if not matches:
            continue
        matches.sort(
            key=lambda c: (
                c["pattern"] != bundle_id,
                not c["has_devices"],
                c["name"].lower(),
            )
        )
        chosen = matches[0]
        provisioning_profiles[bundle_id] = chosen["name"]
        if not team_id and chosen["team_id"]:
            team_id = chosen["team_id"]

print(
    json.dumps(
        {
            "teamID": team_id,
            "bundleIDs": target_bundles,
            "provisioningProfiles": provisioning_profiles,
            "completeProfileMap": len(target_bundles) == len(provisioning_profiles),
        }
    )
)
PY
}

ARCHIVE_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=iOS"
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  -disableAutomaticPackageResolution
  -clonedSourcePackagesDirPath "$SPM_CACHE_DIR"
  -skipPackageUpdates
  COMPILER_INDEX_STORE_ENABLE=NO
  archive
)

if [[ -n "$TEAM_ID" ]]; then
  ARCHIVE_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  ARCHIVE_ARGS=(-allowProvisioningUpdates "${ARCHIVE_ARGS[@]}")
fi

echo "==> Archiving $SCHEME"
PACKAGE_RESOLUTION_STAMP="$DERIVED_DATA/.package-resolution.stamp"
PACKAGE_RESOLVED_PATH="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SHOULD_RESOLVE_PACKAGES=0
if [[ ! -d "$SPM_CACHE_DIR/checkouts" || ! -f "$PACKAGE_RESOLUTION_STAMP" ]]; then
  SHOULD_RESOLVE_PACKAGES=1
elif [[ -f "$PACKAGE_RESOLVED_PATH" && "$PACKAGE_RESOLVED_PATH" -nt "$PACKAGE_RESOLUTION_STAMP" ]]; then
  SHOULD_RESOLVE_PACKAGES=1
fi

if [[ "$SHOULD_RESOLVE_PACKAGES" -eq 1 ]]; then
  echo "==> Resolving Swift packages"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -clonedSourcePackagesDirPath "$SPM_CACHE_DIR" \
    -skipPackageUpdates \
    -resolvePackageDependencies
  touch "$PACKAGE_RESOLUTION_STAMP"
else
  echo "==> Reusing cached Swift packages"
fi
xcodebuild "${ARCHIVE_ARGS[@]}"

detect_export_signing_metadata > "$EXPORT_METADATA_JSON"

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(python3 - <<'PY' "$EXPORT_METADATA_JSON"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
print((data.get("teamID") or "").strip())
PY
)"
fi

PROVISIONING_PROFILES_SNIPPET="$(python3 - <<'PY' "$EXPORT_METADATA_JSON"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
profiles = data.get("provisioningProfiles") or {}
if not data.get("completeProfileMap") or not profiles:
    sys.exit(0)
def is_xcode_managed(name: str) -> bool:
    normalized = (name or "").strip()
    return normalized.startswith("iOS Team Provisioning Profile:") or normalized.startswith("XC ")
if any(is_xcode_managed(name) for name in profiles.values()):
    sys.exit(0)
print("  <key>provisioningProfiles</key>")
print("  <dict>")
for bundle_id in sorted(profiles):
    print(f"    <key>{bundle_id}</key>")
    print(f"    <string>{profiles[bundle_id]}</string>")
print("  </dict>")
PY
)"

EXPORT_SIGNING_STYLE="automatic"
EXPORT_SIGNING_CERTIFICATE=""
if [[ -n "$PROVISIONING_PROFILES_SNIPPET" ]]; then
  EXPORT_SIGNING_STYLE="manual"
  if [[ "$METHOD" == "debugging" ]]; then
    EXPORT_SIGNING_CERTIFICATE="Apple Development"
  else
    EXPORT_SIGNING_CERTIFICATE="Apple Distribution"
  fi
fi

cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>$METHOD</string>
  <key>signingStyle</key>
  <string>$EXPORT_SIGNING_STYLE</string>
$(if [[ -n "$EXPORT_SIGNING_CERTIFICATE" ]]; then cat <<EOF2
  <key>signingCertificate</key>
  <string>$EXPORT_SIGNING_CERTIFICATE</string>
EOF2
fi)
  <key>stripSwiftSymbols</key>
  <true/>
  <key>thinning</key>
  <string>&lt;none&gt;</string>
  <key>manifest</key>
  <dict>
    <key>appURL</key>
    <string>$APP_URL</string>
    <key>displayImageURL</key>
    <string>$DISPLAY_IMAGE_URL</string>
    <key>fullSizeImageURL</key>
    <string>$FULLSIZE_IMAGE_URL</string>
  </dict>
$(if [[ -n "$TEAM_ID" ]]; then cat <<EOF2
  <key>teamID</key>
  <string>$TEAM_ID</string>
EOF2
fi)
$PROVISIONING_PROFILES_SNIPPET
</dict>
</plist>
EOF

echo "==> Export signing context"
if [[ -n "$TEAM_ID" ]]; then
  echo "Team ID: $TEAM_ID"
else
  echo "Team ID: (not detected)"
fi
echo "Signing style: $EXPORT_SIGNING_STYLE"
if [[ -n "$EXPORT_SIGNING_CERTIFICATE" ]]; then
  echo "Signing certificate: $EXPORT_SIGNING_CERTIFICATE"
fi
if [[ -n "$PROVISIONING_PROFILES_SNIPPET" ]]; then
  echo "Provisioning profiles: detected for all archived bundle IDs"
else
  echo "Provisioning profiles: using automatic resolution"
fi

echo "==> Exporting IPA + manifest"
EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  EXPORT_ARGS=(-allowProvisioningUpdates "${EXPORT_ARGS[@]}")
fi

xcodebuild "${EXPORT_ARGS[@]}"

IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -name '*.ipa' | head -n 1)"
MANIFEST_PATH="$EXPORT_PATH/manifest.plist"
if [[ -z "$IPA_PATH" || ! -f "$MANIFEST_PATH" ]]; then
  echo "Expected IPA and manifest.plist in $EXPORT_PATH" >&2
  exit 1
fi

RELEASE_PUBLIC_DIR="$PUBLIC_RELEASES_ROOT/$TIMESTAMP"
mkdir -p "$RELEASE_PUBLIC_DIR"
rm -rf "$PUBLIC_LATEST_ROOT"
mkdir -p "$PUBLIC_LATEST_ROOT"

cp "$IPA_PATH" "$RELEASE_PUBLIC_DIR/$SLUG.ipa"
cp "$MANIFEST_PATH" "$RELEASE_PUBLIC_DIR/manifest.plist"
cp "$IPA_PATH" "$PUBLIC_LATEST_ROOT/$SLUG.ipa"
cp "$MANIFEST_PATH" "$PUBLIC_LATEST_ROOT/manifest.plist"

python3 - <<'PY' "$RELEASE_PUBLIC_DIR/display.png" "$RELEASE_PUBLIC_DIR/fullsize.png" "$PUBLIC_LATEST_ROOT/display.png" "$PUBLIC_LATEST_ROOT/fullsize.png"
import base64, pathlib, sys
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5xN2sAAAAASUVORK5CYII="
)
for path in sys.argv[1:]:
    pathlib.Path(path).write_bytes(png)
PY

cat >"$RELEASE_PUBLIC_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$TITLE - $TIMESTAMP</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px auto; max-width: 680px; padding: 0 16px; line-height: 1.5; }
    .button { display: inline-block; padding: 14px 18px; border-radius: 12px; text-decoration: none; background: #111; color: #fff; }
    code { background: #f3f3f3; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <h1>$TITLE</h1>
  <p>Archived build: $TIMESTAMP</p>
  <p>This is an Apple-signed developer build created on the developer's Mac with Xcode. Installation only succeeds on devices included in the selected Apple provisioning profile.</p>
  <p><a class="button" href="itms-services://?action=download-manifest&url=$RELEASE_MANIFEST_URL">Install this build</a></p>
  <p>Manifest: <code>$RELEASE_MANIFEST_URL</code></p>
  <p>IPA: <code>$RELEASE_APP_URL</code></p>
</body>
</html>
EOF

cat >"$PUBLIC_LATEST_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$TITLE - latest</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px auto; max-width: 680px; padding: 0 16px; line-height: 1.5; }
    .button { display: inline-block; padding: 14px 18px; border-radius: 12px; text-decoration: none; background: #111; color: #fff; }
    code { background: #f3f3f3; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <h1>$TITLE</h1>
  <p>Latest good build alias.</p>
  <p>This is an Apple-signed developer build created on the developer's Mac with Xcode. Installation only succeeds on devices included in the selected Apple provisioning profile.</p>
  <p><a class="button" href="$INSTALL_URL">Install latest build</a></p>
  <p>Manifest: <code>$MANIFEST_URL</code></p>
  <p>IPA: <code>$APP_URL</code></p>
</body>
</html>
EOF

history_items=""
while IFS= read -r release_dir; do
  release_name="$(basename "$release_dir")"
  history_items="${history_items}  <li><a href=\"releases/$release_name/\">$release_name</a></li>"$'\n'
done < <(find "$PUBLIC_RELEASES_ROOT" -mindepth 1 -maxdepth 1 -type d | sort -r)

cat >"$PUBLIC_PROJECT_ROOT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$TITLE</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 40px auto; max-width: 680px; padding: 0 16px; line-height: 1.5; }
    .button { display: inline-block; padding: 14px 18px; border-radius: 12px; text-decoration: none; background: #111; color: #fff; }
    code { background: #f3f3f3; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <h1>$TITLE</h1>
  <p>Open this page in Safari on the target iPhone, then tap install. This is not public app distribution: the IPA was built and signed on the developer's Mac, and iOS only installs it on devices included in the Apple provisioning profile.</p>
  <p><a class="button" href="$INSTALL_URL">Install latest build</a></p>
  <p>Latest manifest: <code>$MANIFEST_URL</code></p>
  <p>Latest IPA: <code>$APP_URL</code></p>
  <p><a href="$PUBLIC_BASE_URL/$SLUG/latest/">Open latest build page</a></p>
  <h2>Archive history</h2>
  <ul>
$history_items  </ul>
</body>
</html>
EOF

echo "==> Verifying DexRelay helper is reachable on 127.0.0.1:$HELPER_PORT"
if ! curl -fsS --max-time 5 "http://127.0.0.1:$HELPER_PORT/health" >/dev/null 2>&1; then
  cat >&2 <<EOF
DexRelay helper is not reachable on 127.0.0.1:$HELPER_PORT.
OTA publish requires the always-on helper service to host artifacts.

Run:
  dexrelay install
or:
  dexrelay repair
EOF
  exit 1
fi

LOCAL_MANIFEST_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$LOCAL_MANIFEST_URL" || true)"
if [[ "$LOCAL_MANIFEST_HTTP_CODE" != "200" ]]; then
  cat >&2 <<EOF
DexRelay helper did not expose the published OTA manifest (HTTP $LOCAL_MANIFEST_HTTP_CODE).
Expected:
  $LOCAL_MANIFEST_URL
EOF
  exit 1
fi

if [[ "$SKIP_TAILSCALE_SERVE" -eq 0 ]]; then
  echo "==> Publishing OTA path over Tailscale HTTPS"
  SERVE_OUTPUT=""
  SERVE_EXIT=1
  for _ in 1 2 3; do
    SERVE_OUTPUT="$(
    python3 - <<'PY' "$HELPER_PORT" "$SLUG"
import subprocess
import sys

helper_port = sys.argv[1]
slug = sys.argv[2]
path = "/" + slug.lstrip("/")
target = f"http://127.0.0.1:{helper_port}/{slug.lstrip('/')}"
cmd = [
    "/Applications/Tailscale.app/Contents/MacOS/tailscale",
    "serve",
    "--bg",
    "--yes",
    "--set-path",
    path,
    target,
]

try:
    completed = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=12,
        check=False,
    )
except subprocess.TimeoutExpired as exc:
    output = ((exc.stdout or "") + (exc.stderr or "")).strip()
    if output:
        print(output)
    print("Timed out waiting for tailscale serve to finish.")
    sys.exit(124)

output = ((completed.stdout or "") + (completed.stderr or "")).strip()
if output:
    print(output)
sys.exit(completed.returncode)
PY
    )"
    SERVE_EXIT=$?
    if [[ "$SERVE_EXIT" -eq 0 ]]; then
      break
    fi
    if printf '%s\n' "$SERVE_OUTPUT" | grep -qi "etag mismatch\\|another client is changing the serve config"; then
      sleep 1
      continue
    fi
    break
  done
  if [[ "$SERVE_EXIT" -ne 0 ]]; then
    cat >&2 <<EOF
Tailscale Serve publish failed.

$SERVE_OUTPUT

If you see "Serve is not enabled on your tailnet", enable it here:
  https://login.tailscale.com/f/serve

If you see "Timed out waiting for tailscale serve to finish", Tailscale likely printed
an interactive/policy message without exiting cleanly. Open this directly:
  https://login.tailscale.com/f/serve

Archive/export output is still available locally:
  $RELEASE_DIR
EOF
    exit 1
  fi
else
  echo "==> Reusing existing Tailscale Serve mapping"
fi

echo "==> Verifying OTA manifest is reachable over Tailscale HTTPS"
MANIFEST_HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 12 "$MANIFEST_URL" || true)"
if [[ "$MANIFEST_HTTP_CODE" != "200" ]]; then
  cat >&2 <<EOF
OTA manifest is unreachable through Tailscale Serve (HTTP $MANIFEST_HTTP_CODE).
Install prompts on iPhone will not appear until this is healthy.

Checks:
  - tailscale serve status
  - Helper health: http://127.0.0.1:$HELPER_PORT/health
  - Local manifest: $LOCAL_MANIFEST_URL
  - Tailscale admin Serve policy enabled

Manifest URL:
  $MANIFEST_URL
EOF
  exit 1
fi

cat <<EOF

Published successfully.

Release directory:
  $RELEASE_DIR

Open on iPhone Safari:
  $PROJECT_PAGE_URL

Direct install URL:
  $INSTALL_URL

Notes:
  - This replaced the current node-level Tailscale Serve HTTPS mapping.
  - Export method used: $METHOD
  - If install fails, confirm the iPhone UDID is included in the export profile.
  - If Safari downloads instead of installing, re-check that manifest.plist is served over HTTPS.
EOF
