#!/usr/bin/env bash

# Resolve a working Xcode developer directory even when xcode-select points to CLT.
# Usage:
#   source "$(dirname "$0")/xcode-devdir.sh"
#   ensure_xcode_developer_dir

ensure_xcode_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" && -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    return 0
  fi

  local selected=""
  selected="$(xcode-select -p 2>/dev/null || true)"

  local candidates=()
  if [[ -n "$selected" ]]; then
    candidates+=("$selected")
  fi
  candidates+=("/Applications/Xcode.app/Contents/Developer")

  local app
  for app in /Applications/Xcode*.app ~/Applications/Xcode*.app; do
    [[ -d "$app" ]] || continue
    candidates+=("$app/Contents/Developer")
  done

  local seen=""
  local candidate=""
  for candidate in "${candidates[@]}"; do
    [[ -d "$candidate" ]] || continue
    case "|$seen|" in
      *"|$candidate|"*) continue ;;
      *) seen="${seen}|${candidate}" ;;
    esac

    if DEVELOPER_DIR="$candidate" xcodebuild -version >/dev/null 2>&1; then
      export DEVELOPER_DIR="$candidate"
      return 0
    fi
  done

  cat >&2 <<'EOF'
Unable to find a working Xcode developer directory.
Install Xcode and set it as active, for example:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
EOF
  return 1
}

detect_xcode_signing_context_json() {
  local project="${1:-}"
  local scheme="${2:-}"
  local configuration="${3:-Debug}"

  if [[ -z "$project" || -z "$scheme" ]]; then
    echo '{"teamID":"","source":"invalid","reason":"project and scheme are required","bundleIDs":[],"projectTeams":[],"candidateTeams":[]}'
    return 1
  fi

  python3 - "$project" "$scheme" "$configuration" <<'PY'
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

project = sys.argv[1]
scheme = sys.argv[2]
configuration = sys.argv[3]


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True)


def app_id_matches(pattern: str, bundle_id: str) -> bool:
    if pattern == bundle_id:
        return True
    if pattern.endswith("*"):
        return bundle_id.startswith(pattern[:-1])
    return False


def parse_mobileprovision(path: Path):
    completed = subprocess.run(
        ["security", "cms", "-D", "-i", str(path)],
        capture_output=True,
    )
    if completed.returncode != 0:
        return None
    try:
        return plistlib.loads(completed.stdout)
    except Exception:
        return None


def local_profile_dirs() -> list[Path]:
    home = Path.home()
    return [
        home / "Library" / "MobileDevice" / "Provisioning Profiles",
        home / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles",
        home / "Library" / "Developer" / "Xcode" / "Provisioning Profiles",
    ]


context: dict[str, object] = {
    "teamID": "",
    "source": "none",
    "reason": "",
    "bundleIDs": [],
    "projectTeams": [],
    "candidateTeams": [],
}

settings = run(
    [
        "xcodebuild",
        "-showBuildSettings",
        "-json",
        "-project",
        project,
        "-scheme",
        scheme,
        "-configuration",
        configuration,
    ]
)

bundle_ids: list[str] = []
project_teams: list[str] = []
if settings.returncode == 0:
    try:
        payload = json.loads(settings.stdout)
    except Exception:
        payload = []
    for item in payload:
        build_settings = item.get("buildSettings") or {}
        team_id = str(build_settings.get("DEVELOPMENT_TEAM") or "").strip()
        if team_id and team_id not in project_teams:
            project_teams.append(team_id)
        wrapper = str(build_settings.get("WRAPPER_EXTENSION") or "").strip()
        bundle_id = str(build_settings.get("PRODUCT_BUNDLE_IDENTIFIER") or "").strip()
        if wrapper in {"app", "appex"} and bundle_id and bundle_id not in bundle_ids:
            bundle_ids.append(bundle_id)

project_file = Path(project) / "project.pbxproj"
if project_file.exists():
    try:
        project_text = project_file.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        project_text = ""

    for match in re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]{10});", project_text):
        team_id = match.strip()
        if team_id and team_id not in project_teams:
            project_teams.append(team_id)

    for match in re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);", project_text):
        bundle_id = match.strip().strip('"')
        if not bundle_id or "$(" in bundle_id or bundle_id in bundle_ids:
            continue
        bundle_ids.append(bundle_id)

context["bundleIDs"] = bundle_ids
context["projectTeams"] = project_teams

if len(project_teams) == 1:
    context["teamID"] = project_teams[0]
    context["source"] = "project_build_settings"
    print(json.dumps(context))
    raise SystemExit(0)

if len(project_teams) > 1:
    context["source"] = "ambiguous"
    context["candidateTeams"] = project_teams
    context["reason"] = "Multiple development teams were found in the project build settings."
    print(json.dumps(context))
    raise SystemExit(0)

profile_candidates: list[dict[str, str | bool]] = []
for directory in local_profile_dirs():
    if not directory.exists():
        continue
    for pattern in ("*.mobileprovision", "*.provisionprofile"):
        for path in directory.glob(pattern):
            profile = parse_mobileprovision(path)
            if not profile:
                continue
            teams = profile.get("TeamIdentifier") or []
            team_id = str(teams[0]).strip() if teams else ""
            if not team_id:
                continue
            entitlements = profile.get("Entitlements") or {}
            application_identifier = str(entitlements.get("application-identifier") or "").strip()
            if "." not in application_identifier:
                continue
            _, _, pattern_value = application_identifier.partition(".")
            if not pattern_value:
                continue
            provisioned_devices = profile.get("ProvisionedDevices") or []
            profile_candidates.append(
                {
                    "team_id": team_id,
                    "pattern": pattern_value,
                    "name": str(profile.get("Name") or "").strip(),
                    "get_task_allow": bool(entitlements.get("get-task-allow")),
                    "has_devices": bool(provisioned_devices),
                }
            )

profile_scores: dict[str, int] = {}
for bundle_id in bundle_ids:
    matches = [
        candidate
        for candidate in profile_candidates
        if app_id_matches(str(candidate["pattern"]), bundle_id)
        and bool(candidate["get_task_allow"])
        and bool(candidate["has_devices"])
    ]
    seen_teams: set[str] = set()
    for candidate in matches:
        team_id = str(candidate["team_id"])
        if team_id in seen_teams:
            continue
        seen_teams.add(team_id)
        score = 4 if str(candidate["pattern"]) == bundle_id else 2
        name = str(candidate["name"])
        if name.startswith("XC ") or name.startswith("iOS Team Provisioning Profile:"):
            score += 1
        profile_scores[team_id] = profile_scores.get(team_id, 0) + score

if profile_scores:
    ranked = sorted(profile_scores.items(), key=lambda item: (-item[1], item[0]))
    top_score = ranked[0][1]
    top_teams = [team_id for team_id, score in ranked if score == top_score]
    context["candidateTeams"] = [team_id for team_id, _ in ranked]
    if len(top_teams) == 1:
        context["teamID"] = top_teams[0]
        context["source"] = "matching_provisioning_profile"
        print(json.dumps(context))
        raise SystemExit(0)
    context["source"] = "ambiguous"
    context["reason"] = "Multiple provisioning profiles match this project's bundle identifiers."
    print(json.dumps(context))
    raise SystemExit(0)

identity_output = run(["security", "find-identity", "-v", "-p", "codesigning"])
identity_lines = identity_output.stdout + "\n" + identity_output.stderr
development_teams = sorted(
    set(
        re.findall(
            r'"(?:Apple Development|iPhone Developer): [^"]+ \(([A-Z0-9]{10})\)"',
            identity_lines,
        )
    )
)

if len(development_teams) == 1:
    context["teamID"] = development_teams[0]
    context["source"] = "codesign_identity"
    context["candidateTeams"] = development_teams
    print(json.dumps(context))
    raise SystemExit(0)

if len(development_teams) > 1:
    context["source"] = "ambiguous"
    context["candidateTeams"] = development_teams
    context["reason"] = "Multiple Apple Development identities are installed for this Mac user."
    print(json.dumps(context))
    raise SystemExit(0)

context["reason"] = "No development team was found in the project, local provisioning profiles, or Apple Development identities."
print(json.dumps(context))
PY
}
