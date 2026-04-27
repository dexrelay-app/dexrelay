#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
COMMAND_CENTER_DIR = PROJECT_ROOT / "command-center"
GLOBAL_GOVERNANCE_PATH = COMMAND_CENTER_DIR / "codex-governance.json"
DISCOVERED_PROJECTS_PATH = COMMAND_CENTER_DIR / "discovered-projects.json"
SERVICES_REGISTRY_PATH = SCRIPT_DIR / "services.registry.json"
DEFAULT_BASE_DIR = Path(os.environ.get("CODEX_RELAY_PROJECTS_ROOT", str(Path.home() / "src"))).expanduser()
PROJECT_STATE_DIRECTORY_NAME = ".dexrelay"
LEGACY_PROJECT_STATE_DIRECTORY_NAME = ".codex"
PROJECT_RUNBOOK_RELATIVE_PATH = Path(f"{PROJECT_STATE_DIRECTORY_NAME}/project-runbook.json")
PROJECT_GOVERNANCE_RELATIVE_PATH = Path(f"{PROJECT_STATE_DIRECTORY_NAME}/project-governance.json")
PROJECT_PLANNING_RELATIVE_PATH = Path(f"{PROJECT_STATE_DIRECTORY_NAME}/project-planning.md")
LEGACY_PROJECT_RUNBOOK_RELATIVE_PATH = Path(f"{LEGACY_PROJECT_STATE_DIRECTORY_NAME}/project-runbook.json")
LEGACY_PROJECT_GOVERNANCE_RELATIVE_PATH = Path(f"{LEGACY_PROJECT_STATE_DIRECTORY_NAME}/project-governance.json")
LEGACY_PROJECT_PLANNING_RELATIVE_PATH = Path(f"{LEGACY_PROJECT_STATE_DIRECTORY_NAME}/project-planning.md")
APP_SCREENSHOT_STUDIO_RELATIVE_PATH = Path(f"{PROJECT_STATE_DIRECTORY_NAME}/app-screenshot-studio")
LEGACY_APP_SCREENSHOT_STUDIO_RELATIVE_PATH = Path(f"{LEGACY_PROJECT_STATE_DIRECTORY_NAME}/app-screenshot-studio")
ARTIFACTS_RELATIVE_PATH = Path(f"{PROJECT_STATE_DIRECTORY_NAME}/artifacts")
LEGACY_ARTIFACTS_RELATIVE_PATH = Path(f"{LEGACY_PROJECT_STATE_DIRECTORY_NAME}/artifacts")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def print_json(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, indent=2, sort_keys=False))


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def migrate_legacy_dexrelay_state(project_path: Path) -> list[str]:
    migrated: list[str] = []
    project_state_dir = project_path / PROJECT_STATE_DIRECTORY_NAME

    file_migrations = [
        (LEGACY_PROJECT_RUNBOOK_RELATIVE_PATH, PROJECT_RUNBOOK_RELATIVE_PATH),
        (LEGACY_PROJECT_GOVERNANCE_RELATIVE_PATH, PROJECT_GOVERNANCE_RELATIVE_PATH),
        (LEGACY_PROJECT_PLANNING_RELATIVE_PATH, PROJECT_PLANNING_RELATIVE_PATH),
    ]

    for legacy_relative_path, new_relative_path in file_migrations:
        legacy_path = project_path / legacy_relative_path
        new_path = project_path / new_relative_path
        if legacy_path.exists() and not new_path.exists():
            new_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(legacy_path), str(new_path))
            migrated.append(f"{legacy_relative_path} -> {new_relative_path}")

    directory_migrations = [
        (LEGACY_APP_SCREENSHOT_STUDIO_RELATIVE_PATH, APP_SCREENSHOT_STUDIO_RELATIVE_PATH),
        (LEGACY_ARTIFACTS_RELATIVE_PATH, ARTIFACTS_RELATIVE_PATH),
    ]

    for legacy_relative_path, new_relative_path in directory_migrations:
        legacy_path = project_path / legacy_relative_path
        new_path = project_path / new_relative_path
        if legacy_path.exists() and not new_path.exists():
            new_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(legacy_path), str(new_path))
            migrated.append(f"{legacy_relative_path} -> {new_relative_path}")

    legacy_root = project_path / LEGACY_PROJECT_STATE_DIRECTORY_NAME
    if legacy_root.exists() and legacy_root.is_dir():
        try:
            next(legacy_root.iterdir())
        except StopIteration:
            legacy_root.rmdir()
            migrated.append(f"removed empty {LEGACY_PROJECT_STATE_DIRECTORY_NAME}/")

    if migrated and not project_state_dir.exists():
        project_state_dir.mkdir(parents=True, exist_ok=True)

    return migrated


def load_registry(path: Path = SERVICES_REGISTRY_PATH) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "services": [], "portPolicy": {}}
    data = load_json(path)
    if not isinstance(data, dict):
        raise ValueError(f"invalid services registry root: {path}")
    services = data.get("services")
    if not isinstance(services, list):
        raise ValueError("services registry must contain a list in 'services'")
    return data


def codex_config_project_paths(config_path: Path) -> list[Path]:
    if not config_path.exists():
        return []
    if tomllib is not None:
        try:
            config = tomllib.loads(config_path.read_text(encoding="utf-8"))
            config_projects = config.get("projects", {})
            if isinstance(config_projects, dict):
                return [Path(raw_path) for raw_path in sorted(config_projects.keys(), key=str.lower)]
        except Exception:
            return []

    # Python 3.9 has no tomllib. Codex config project keys are TOML strings
    # under [projects], so parse only that narrow, stable shape.
    paths: list[Path] = []
    in_projects = False
    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        table_match = re.match(r'^\[projects\."(.+)"\]$', line)
        if table_match:
            try:
                paths.append(Path(json.loads(f'"{table_match.group(1)}"')))
            except Exception:
                paths.append(Path(table_match.group(1)))
            in_projects = False
            continue
        if line.startswith("[") and line.endswith("]"):
            in_projects = line == "[projects]"
            continue
        if not in_projects or "=" not in line:
            continue
        key = line.split("=", 1)[0].strip()
        if len(key) >= 2 and key[0] == '"' and key[-1] == '"':
            try:
                paths.append(Path(json.loads(key)))
            except Exception:
                continue
    return sorted(paths, key=lambda path: str(path).lower())


def discover_projects(base_dir: Path) -> list[dict[str, str]]:
    seen: set[str] = set()
    projects: list[dict[str, str]] = []

    def add_project(path: Path) -> None:
        try:
            resolved = path.expanduser().resolve()
        except OSError:
            resolved = path.expanduser()
        normalized = str(resolved)
        if normalized in seen or not resolved.is_dir():
            return
        seen.add(normalized)
        projects.append({"name": resolved.name, "path": normalized})

    if not base_dir.exists():
        pass
    else:
        for child in sorted(base_dir.iterdir(), key=lambda p: p.name.lower()):
            add_project(child)

    config_path = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "config.toml"
    for raw_path in codex_config_project_paths(config_path):
        add_project(raw_path)

    projects.sort(key=lambda item: item["name"].lower())
    return projects


def detect_project_type(project_path: Path) -> str:
    xcode_projects = list(project_path.glob("*.xcodeproj"))
    if xcode_projects:
        for xcode_project in xcode_projects:
            pbxproj = xcode_project / "project.pbxproj"
            if not pbxproj.exists():
                continue
            try:
                text = pbxproj.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if "SDKROOT = macosx;" in text or "MACOSX_DEPLOYMENT_TARGET" in text or 'SUPPORTED_PLATFORMS = "macosx";' in text:
                return "mac-app"
        return "ios-app"
    package_json = project_path / "package.json"
    if package_json.exists():
        try:
            package = json.loads(package_json.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            package = {}
        dependencies = {
            **(package.get("dependencies") or {}),
            **(package.get("devDependencies") or {}),
        }
        scripts = package.get("scripts") or {}
        if "vite" in dependencies or ("react" in dependencies and "dev" in scripts):
            return "web-app"
        return "node-app"
    if (project_path / "pyproject.toml").exists() or (project_path / "requirements.txt").exists():
        return "python-app"
    if (project_path / "docker-compose.yml").exists() or (project_path / "compose.yaml").exists():
        return "docker-stack"
    return "folder"


def clipped_line(text: str, limit: int = 96) -> str:
    normalized = re.sub(r"\s+", " ", text).strip()
    if len(normalized) <= limit:
        return normalized
    clipped = normalized[:limit].rstrip()
    if " " in clipped:
        clipped = clipped.rsplit(" ", 1)[0]
    return clipped.rstrip(" .,;:-") + "..."


def is_placeholder_description(text: str) -> bool:
    normalized = re.sub(r"\s+", " ", text).strip().lower()
    if not normalized:
        return True
    prefixes = (
        "project path:",
        "xcode project:",
        "scheme:",
        "bundle id:",
        "start the local backend:",
        "to make it easy for you to get started with gitlab",
        "already a pro? just edit this readme.md",
        "- [ ]",
        "created from codex iphone to mac relay",
    )
    if normalized.startswith(prefixes):
        return True
    return False


def extract_readme_summary(project_path: Path) -> str | None:
    for name in ("README.md", "README.MD", "readme.md", "README.txt", "README"):
        readme_path = project_path / name
        if not readme_path.exists():
            continue
        try:
            lines = readme_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for raw in lines:
            line = raw.strip()
            if not line:
                continue
            if line.startswith("#"):
                continue
            if line.startswith("```"):
                break
            if len(line) < 12:
                continue
            if line.lower().startswith(("created from ", "generated by ", "copyright ", "license")):
                continue
            if line.endswith(":"):
                continue
            if is_placeholder_description(line):
                continue
            return clipped_line(line)
    return None


def extract_package_description(project_path: Path) -> str | None:
    package_path = project_path / "package.json"
    if not package_path.exists():
        return None
    try:
        payload = json.loads(package_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    description = str(payload.get("description", "")).strip()
    if not description or is_placeholder_description(description):
        return None
    return clipped_line(description)


def extract_pyproject_description(project_path: Path) -> str | None:
    if tomllib is None:
        return None
    pyproject_path = project_path / "pyproject.toml"
    if not pyproject_path.exists():
        return None
    try:
        payload = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return None
    candidates = [
        payload.get("project", {}).get("description"),
        payload.get("tool", {}).get("poetry", {}).get("description"),
    ]
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            if is_placeholder_description(candidate):
                continue
            return clipped_line(candidate)
    return None


def inferred_project_description(project_path: Path, project_name: str, project_type: str, service_rows: list[dict[str, Any]]) -> str:
    for extractor in (extract_package_description, extract_pyproject_description, extract_readme_summary):
        value = extractor(project_path)
        if value:
            return value

    name = project_name.lower()
    pretty_name = re.sub(r"[_\-]+", " ", project_name).strip()
    if "stock" in name or "ath" in name:
        return "Track stocks and analyze all-time-high setups."
    if "gif" in name:
        return "Create GIFs or short motion exports from source media."
    if "tamagotchi" in name or "sprite" in name:
        return "Build and animate pixel-character experiences."
    if "tip" in name or "calculator" in name:
        return "A lightweight utility for quick calculations and everyday helpers."
    if "audio" in name or "music" in name:
        return "Process, manage, or generate audio-focused workflows."
    if "codex" in name or "relay" in name:
        return "Remote-control and automation tooling for Codex workflows."
    if "icon" in name:
        return "Generate, refine, or package app icon concepts and assets."
    if "upscal" in name:
        return "Upscale and enhance source images or videos."
    if "video" in name:
        return "Edit, transform, or extract assets from video inputs."
    if "mail" in name:
        return "Email workflow tooling and mail-focused product experiments."
    if "game" in name:
        return "Prototype and ship a focused app experience."
    if project_type == "ios-app":
        return f"iOS app project for {pretty_name}."
    if project_type == "mac-app":
        return f"Mac app project for {pretty_name}."
    if project_type == "web-app":
        return f"Web app project for {pretty_name}."
    if project_type == "node-app":
        return f"Web or Node app for {pretty_name}."
    if project_type == "python-app":
        return f"Python app or backend for {pretty_name}."
    if project_type == "docker-stack":
        return f"Containerized stack for {pretty_name}."
    if service_rows:
        return "Project workspace with a managed local backend service."
    return f"Working repo for {clipped_line(project_name, limit=64)}."


def existing_governance_description(project_path: Path) -> str | None:
    governance_path = project_path / PROJECT_GOVERNANCE_RELATIVE_PATH
    if not governance_path.exists():
        return None
    try:
        payload = load_json(governance_path)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    description = str(payload.get("description", "")).strip()
    if not description or is_placeholder_description(description):
        return None
    return clipped_line(description)


def existing_governance_services(project_path: Path) -> list[dict[str, Any]]:
    governance_path = project_path / PROJECT_GOVERNANCE_RELATIVE_PATH
    if not governance_path.exists():
        return []
    try:
        payload = load_json(governance_path)
    except Exception:
        return []
    if not isinstance(payload, dict):
        return []
    services = payload.get("services")
    if not isinstance(services, list):
        return []
    return [service for service in services if isinstance(service, dict)]


def service_identity(service: dict[str, Any]) -> str:
    raw_id = str(service.get("serviceId") or service.get("id") or "").strip()
    if raw_id:
        return raw_id
    name = str(service.get("name") or "").strip()
    ports = service.get("ports") if isinstance(service.get("ports"), list) else []
    return f"{name}:{','.join(str(port) for port in ports)}"


def merge_project_services(existing: list[dict[str, Any]], discovered: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    for service in existing + discovered:
        key = service_identity(service)
        if not key:
            continue
        merged[key] = service
    return list(merged.values())


def normalize_service(service: dict[str, Any]) -> dict[str, Any]:
    ports = [p for p in service.get("ports", []) if isinstance(p, int)]
    raw_exposure = service.get("exposure", {})
    exposure = raw_exposure if isinstance(raw_exposure, dict) else {}
    return {
        "serviceId": str(service.get("id", "")).strip(),
        "name": str(service.get("name", "")).strip(),
        "ports": ports,
        "openPath": str(service.get("openPath", "")).strip(),
        "exposure": {
            "mode": str(exposure.get("mode", "")).strip(),
            "path": str(exposure.get("path", "")).strip(),
            "target": str(exposure.get("target", "")).strip(),
        },
        "tags": [str(tag) for tag in service.get("tags", []) if str(tag).strip()],
        "healthCheck": str(service.get("healthCheck", "")).strip(),
        "startCommand": str(service.get("startCommand", "")).strip(),
        "stopCommand": str(service.get("stopCommand", "")).strip(),
        "restartCommand": str(service.get("restartCommand", "")).strip(),
    }


def services_by_project(registry: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for raw in registry.get("services", []):
        if not isinstance(raw, dict):
            continue
        project_path = str(raw.get("projectPath", "")).strip()
        if not project_path or project_path == "*":
            continue
        grouped.setdefault(project_path, []).append(normalize_service(raw))
    for rows in grouped.values():
        rows.sort(key=lambda item: item["serviceId"])
    return grouped


def default_governance_rules() -> dict[str, Any]:
    return {
        "sourceOfTruth": "Project-local .dexrelay files indexed by Codex iPhone Command Center",
        "requiredFiles": [
            str(PROJECT_RUNBOOK_RELATIVE_PATH),
            str(PROJECT_GOVERNANCE_RELATIVE_PATH),
        ],
        "persistence": "Store governance inside each project folder so app reinstalls, relay reinstalls, or moving to a different Mac can rebuild the command-center index by rescanning repos.",
        "backendLifecycle": "All local backends must be started, restarted, or stopped via Codex command center.",
        "portAllocation": "All local backend ports must be allocated from scripts/services.registry.json.",
        "codexInstruction": "Read .dexrelay/project-runbook.json and .dexrelay/project-governance.json before changing backend, deployment, or infrastructure.",
        "tailnetTransport": "Phone-to-Mac control happens over the user's Tailscale tailnet.",
    }


def default_project_runbook(project_name: str, project_type: str, has_services: bool = False) -> dict[str, Any]:
    actions: list[dict[str, Any]] = [
        {
            "id": "review-governance",
            "title": "Review Governance",
            "subtitle": "Inspect the project governance and runbook before changing services.",
            "icon": "doc.text",
            "kind": "shell",
            "command": "cat .dexrelay/project-governance.json && printf '\\n\\n' && cat .dexrelay/project-runbook.json",
            "timeoutMs": 15000,
            "executionMode": "direct-then-codex",
            "showInQuickActions": False,
        }
    ]

    primary_action_id = "review-governance"
    if has_services:
        actions.insert(
            0,
            {
                "id": "open-project-primary-service",
                "title": "Open Service",
                "subtitle": "Open the current phone-ready URL for this project's primary managed service.",
                "icon": "globe",
                "kind": "builtin",
                "builtin": "open-project-primary-service",
                "cwd": "",
                "executionMode": "direct-then-codex",
            },
        )
        primary_action_id = "open-project-primary-service"

    if project_type == "ios-app":
        primary_action_id = "build-ios-ota-distribution"
        actions.extend(
            [
                {
                    "id": "run-ios-on-phone",
                    "title": "Run on This iPhone",
                    "subtitle": "Build, install, and launch the app over Xcode device services.",
                    "icon": "iphone",
                    "kind": "builtin",
                    "builtin": "run-ios-on-phone",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "open-latest-smoke-results",
                    "title": "Open Latest Smoke Results",
                    "subtitle": "Browse the latest smoke summary, screenshots, and logs from this project.",
                    "icon": "photo.on.rectangle",
                    "kind": "builtin",
                    "builtin": "open-latest-smoke-results",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "prepare-ios-testflight",
                    "title": "Prepare for TestFlight",
                    "subtitle": "Create or verify Apple-side bundle IDs, signing prep, and an internal TestFlight group.",
                    "icon": "testtube.2",
                    "kind": "builtin",
                    "builtin": "prepare-ios-testflight",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "build-ios-ota-distribution",
                    "title": "Build Distribution Install",
                    "subtitle": "Create an ad hoc distribution IPA with the production icon.",
                    "icon": "shippingbox",
                    "kind": "builtin",
                    "builtin": "build-ios-ota-distribution",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "open-latest-install-distribution",
                    "title": "Install Distribution Build",
                    "subtitle": "Open the latest distribution install link for this project.",
                    "icon": "shippingbox",
                    "kind": "builtin",
                    "builtin": "open-latest-install-distribution",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "build-ios-ota-debug",
                    "title": "Build Debug Install",
                    "subtitle": "Create an installable debug IPA with the white-background debug icon.",
                    "icon": "antenna.radiowaves.left.and.right",
                    "kind": "builtin",
                    "builtin": "build-ios-ota-debug",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
                {
                    "id": "open-latest-install-debug",
                    "title": "Install Debug Build",
                    "subtitle": "Open the latest debug install link for this project.",
                    "icon": "square.and.arrow.down",
                    "kind": "builtin",
                    "builtin": "open-latest-install-debug",
                    "cwd": "",
                    "executionMode": "direct-then-codex",
                },
            ]
        )
    elif project_type == "web-app":
        primary_action_id = "web-dev-server"
        actions.extend(
            [
                {
                    "id": "web-install-dependencies",
                    "title": "Install Dependencies",
                    "subtitle": "Install the web app dependencies with npm.",
                    "icon": "shippingbox",
                    "kind": "shell",
                    "command": "npm install",
                    "timeoutMs": 120000,
                    "executionMode": "direct-then-codex",
                    "showInQuickActions": True,
                },
                {
                    "id": "web-dev-server",
                    "title": "Start Web Dev Server",
                    "subtitle": "Run Vite on all interfaces so DexRelay can expose it.",
                    "icon": "globe",
                    "kind": "shell",
                    "command": "npm run dev",
                    "timeoutMs": 15000,
                    "executionMode": "direct-then-codex",
                    "showInQuickActions": True,
                },
                {
                    "id": "web-build",
                    "title": "Build Web App",
                    "subtitle": "Typecheck and create a production build.",
                    "icon": "hammer",
                    "kind": "shell",
                    "command": "npm run build",
                    "timeoutMs": 120000,
                    "executionMode": "direct-then-codex",
                    "showInQuickActions": True,
                },
            ]
        )

    return {
        "version": 1,
        "title": f"{project_name} Runbook",
        "summary": "Project-local operating runbook governed by Codex Command Center. Keep this file in the repo so any Mac can rebuild project actions after a rescan.",
        "primaryActionID": primary_action_id,
        "actions": actions,
    }


def build_project_governance(
    project_name: str,
    project_path: Path,
    project_type: str,
    service_rows: list[dict[str, Any]],
    runbook_exists: bool,
    description: str,
) -> dict[str, Any]:
    backend_mode = "local-managed" if service_rows else "none"
    return {
        "version": 1,
        "projectName": project_name,
        "projectPath": str(project_path),
        "projectType": project_type,
        "description": description,
        "managedBy": "Codex iPhone Command Center",
        "storage": {
            "mode": "project-local",
            "folder": ".dexrelay",
            "persistsAcrossReinstall": True,
            "rebuildInstruction": "Rescan projects or run governancectl.py update-project/update-all on any Mac that has this repo checked out.",
        },
        "backendMode": backend_mode,
        "runbookPath": str(PROJECT_RUNBOOK_RELATIVE_PATH),
        "governanceRules": default_governance_rules(),
        "services": service_rows,
        "codexInstructions": [
            "Read .dexrelay/project-runbook.json before taking action.",
            "Read .dexrelay/project-governance.json before changing backend, deployment target, or ports.",
            "If a local backend is needed, register it through the command center so port allocation stays unique.",
            "If the backend moves to Cloudflare or another external platform, update backendMode and deployment notes here before changing runtime wiring.",
        ],
        "runbookPresent": runbook_exists,
        "lastSyncedAt": now_iso(),
    }


def ensure_project_files(project_name: str, project_path: Path, service_rows: list[dict[str, Any]], *, adopt_missing: bool, write_runbook: bool) -> dict[str, Any]:
    migrated_paths = migrate_legacy_dexrelay_state(project_path)
    dexrelay_dir = project_path / PROJECT_STATE_DIRECTORY_NAME
    runbook_path = project_path / PROJECT_RUNBOOK_RELATIVE_PATH
    governance_path = project_path / PROJECT_GOVERNANCE_RELATIVE_PATH
    project_type = detect_project_type(project_path)
    service_rows = merge_project_services(existing_governance_services(project_path), service_rows)

    runbook_exists = runbook_path.exists()
    governance_exists = governance_path.exists()
    description = existing_governance_description(project_path) or inferred_project_description(project_path, project_name, project_type, service_rows)
    wrote_runbook = False
    wrote_governance = False

    if write_runbook and not runbook_exists:
        dexrelay_dir.mkdir(parents=True, exist_ok=True)
        save_json(runbook_path, default_project_runbook(project_name, project_type, bool(service_rows)))
        runbook_exists = True
        wrote_runbook = True

    should_write_governance = adopt_missing or governance_exists or bool(service_rows) or runbook_exists
    if should_write_governance:
        dexrelay_dir.mkdir(parents=True, exist_ok=True)
        payload = build_project_governance(project_name, project_path, project_type, service_rows, runbook_exists, description)
        save_json(governance_path, payload)
        governance_exists = True
        wrote_governance = True

    issues: list[str] = []
    if not runbook_exists:
        issues.append("missing .dexrelay/project-runbook.json")
    if not governance_exists:
        issues.append("missing .dexrelay/project-governance.json")
    if service_rows and not governance_exists:
        issues.append("registered backend exists but project governance file is missing")

    if issues:
        managed_state = "warning" if (runbook_exists or governance_exists or service_rows) else "unmanaged"
    else:
        managed_state = "managed" if (runbook_exists or governance_exists or service_rows) else "unmanaged"

    return {
        "projectName": project_name,
        "projectPath": str(project_path),
        "projectType": project_type,
        "description": description,
        "managedState": managed_state,
        "runbook": {
            "path": str(runbook_path),
            "exists": runbook_exists,
            "generated": wrote_runbook,
        },
        "governance": {
            "path": str(governance_path),
            "exists": governance_exists,
            "generated": wrote_governance,
        },
        "backendMode": "local-managed" if service_rows else "none",
        "services": service_rows,
        "migratedPaths": migrated_paths,
        "issues": issues,
    }


def reconcile(base_dir: Path, *, adopt_missing: bool, write_runbooks: bool) -> dict[str, Any]:
    registry = load_registry()
    projects = discover_projects(base_dir)
    project_services = services_by_project(registry)
    records: list[dict[str, Any]] = []

    known_paths = {project["path"] for project in projects}
    for path in sorted(project_services.keys()):
        if path not in known_paths:
            projects.append({"name": Path(path).name, "path": path})
    projects.sort(key=lambda item: item["name"].lower())

    for project in projects:
        project_path = Path(project["path"])
        service_rows = project_services.get(project["path"], [])
        record = ensure_project_files(
            project["name"],
            project_path,
            service_rows,
            adopt_missing=adopt_missing,
            write_runbook=write_runbooks,
        )
        records.append(record)

    records.sort(key=lambda item: item["projectName"].lower())

    managed = sum(1 for item in records if item["managedState"] == "managed")
    warnings = sum(1 for item in records if item["managedState"] == "warning")
    unmanaged = sum(1 for item in records if item["managedState"] == "unmanaged")
    service_count = sum(len(item["services"]) for item in records)
    missing = [
        {"name": item["projectName"], "path": item["projectPath"], "issues": item["issues"]}
        for item in records
        if item["managedState"] != "managed"
    ]

    global_payload = {
        "version": 1,
        "generatedAt": now_iso(),
        "baseDirectory": str(base_dir),
        "registryPath": str(SERVICES_REGISTRY_PATH),
        "rules": default_governance_rules(),
        "stats": {
            "projectCount": len(records),
            "managedProjectCount": managed,
            "warningProjectCount": warnings,
            "unmanagedProjectCount": unmanaged,
            "registeredServiceCount": service_count,
        },
        "projects": records,
    }
    discovered_payload = {
        "scannedAt": global_payload["generatedAt"],
        "projectCount": len(records),
        "registeredProjectCount": sum(1 for item in records if item["services"]),
        "missingProjectCount": len(missing),
        "missingProjects": missing,
    }

    save_json(GLOBAL_GOVERNANCE_PATH, global_payload)
    save_json(DISCOVERED_PROJECTS_PATH, discovered_payload)

    return {
        "ok": True,
        "snapshotPath": str(GLOBAL_GOVERNANCE_PATH),
        "discoveredProjectsPath": str(DISCOVERED_PROJECTS_PATH),
        **global_payload,
        "missingProjectCount": discovered_payload["missingProjectCount"],
        "missingProjects": discovered_payload["missingProjects"],
        "registeredProjectCount": discovered_payload["registeredProjectCount"],
    }


def cmd_reconcile(args: argparse.Namespace) -> int:
    payload = reconcile(Path(args.base_dir), adopt_missing=args.adopt_missing, write_runbooks=args.write_runbooks)
    if args.json:
        print_json(payload)
    else:
        print(f"governance snapshot: {payload['snapshotPath']}")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    if not GLOBAL_GOVERNANCE_PATH.exists():
        payload = reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    else:
        payload = load_json(GLOBAL_GOVERNANCE_PATH)
        if not isinstance(payload, dict):
            raise ValueError("invalid governance summary file")
        payload = {"ok": True, **payload}
    if args.json:
        print_json(payload)
    else:
        stats = payload.get("stats", {}) if isinstance(payload.get("stats"), dict) else {}
        print(f"projects={stats.get('projectCount', 0)} managed={stats.get('managedProjectCount', 0)} warnings={stats.get('warningProjectCount', 0)} unmanaged={stats.get('unmanagedProjectCount', 0)}")
    return 0


def cmd_ensure_project(args: argparse.Namespace) -> int:
    project_path = Path(args.project_path)
    project_name = args.project_name or project_path.name
    registry = load_registry()
    service_rows = services_by_project(registry).get(str(project_path), [])
    payload = ensure_project_files(
        project_name,
        project_path,
        service_rows,
        adopt_missing=True,
        write_runbook=args.write_runbook,
    )
    reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    out = {"ok": True, **payload}
    if args.json:
        print_json(out)
    else:
        print(f"ensured project governance for {project_path}")
    return 0


def cmd_bind_service(args: argparse.Namespace) -> int:
    project_path = Path(args.project_path)
    if str(project_path).strip() == "*":
        payload = {"ok": True, "message": "global service does not bind to a project governance file"}
        if args.json:
            print_json(payload)
        else:
            print(payload["message"])
        return 0
    registry = load_registry()
    service_rows = services_by_project(registry).get(str(project_path), [])
    if args.service_id and args.service_id not in {row["serviceId"] for row in service_rows}:
        payload = {"ok": False, "error": f"service '{args.service_id}' is not registered for {project_path}"}
        if args.json:
            print_json(payload)
        else:
            print(payload["error"])
        return 1
    record = ensure_project_files(
        args.project_name or project_path.name,
        project_path,
        service_rows,
        adopt_missing=True,
        write_runbook=args.write_runbook,
    )
    reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    out = {"ok": True, **record}
    if args.json:
        print_json(out)
    else:
        print(f"bound services for {project_path}")
    return 0


def cmd_update_project(args: argparse.Namespace) -> int:
    project_path = Path(args.project_path)
    project_name = args.project_name or project_path.name
    registry = load_registry()
    service_rows = services_by_project(registry).get(str(project_path), [])
    payload = ensure_project_files(
        project_name,
        project_path,
        service_rows,
        adopt_missing=True,
        write_runbook=True,
    )
    reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    out = {"ok": True, "mode": "project", **payload}
    if args.json:
        print_json(out)
    else:
        print(f"updated governance for {project_path}")
    return 0


def cmd_update_unmanaged(args: argparse.Namespace) -> int:
    baseline = reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    registry = load_registry()
    service_map = services_by_project(registry)
    updated: list[dict[str, Any]] = []

    for record in baseline.get("projects", []):
        if not isinstance(record, dict):
            continue
        if record.get("managedState") == "managed":
            continue
        project_path = Path(str(record.get("projectPath", "")).strip())
        if not str(project_path):
            continue
        updated.append(
            ensure_project_files(
                str(record.get("projectName") or project_path.name),
                project_path,
                service_map.get(str(project_path), []),
                adopt_missing=True,
                write_runbook=True,
            )
        )

    payload = reconcile(Path(args.base_dir), adopt_missing=False, write_runbooks=False)
    out = {
        "ok": True,
        "mode": "unmanaged",
        "updatedProjectCount": len(updated),
        "updatedProjects": updated,
        **payload,
    }
    if args.json:
        print_json(out)
    else:
        print(f"updated governance for {len(updated)} unmanaged projects")
    return 0


def cmd_update_all(args: argparse.Namespace) -> int:
    payload = reconcile(Path(args.base_dir), adopt_missing=True, write_runbooks=True)
    out = {"ok": True, "mode": "all", **payload}
    if args.json:
        print_json(out)
    else:
        print(f"updated governance for all projects under {args.base_dir}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex project governance command center")
    parser.add_argument("--base-dir", default=str(DEFAULT_BASE_DIR))
    sub = parser.add_subparsers(dest="command", required=True)

    reconcile_cmd = sub.add_parser("reconcile")
    reconcile_cmd.add_argument("--adopt-missing", action="store_true")
    reconcile_cmd.add_argument("--write-runbooks", action="store_true")
    reconcile_cmd.add_argument("--json", action="store_true")

    summary_cmd = sub.add_parser("summary")
    summary_cmd.add_argument("--json", action="store_true")

    ensure_cmd = sub.add_parser("ensure-project")
    ensure_cmd.add_argument("--project-path", required=True)
    ensure_cmd.add_argument("--project-name")
    ensure_cmd.add_argument("--write-runbook", action="store_true")
    ensure_cmd.add_argument("--json", action="store_true")

    bind_cmd = sub.add_parser("bind-service")
    bind_cmd.add_argument("--project-path", required=True)
    bind_cmd.add_argument("--project-name")
    bind_cmd.add_argument("--service-id")
    bind_cmd.add_argument("--write-runbook", action="store_true")
    bind_cmd.add_argument("--json", action="store_true")

    update_project_cmd = sub.add_parser("update-project")
    update_project_cmd.add_argument("--project-path", required=True)
    update_project_cmd.add_argument("--project-name")
    update_project_cmd.add_argument("--json", action="store_true")

    update_unmanaged_cmd = sub.add_parser("update-unmanaged")
    update_unmanaged_cmd.add_argument("--json", action="store_true")

    update_all_cmd = sub.add_parser("update-all")
    update_all_cmd.add_argument("--json", action="store_true")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if args.command == "reconcile":
        return cmd_reconcile(args)
    if args.command == "summary":
        return cmd_summary(args)
    if args.command == "ensure-project":
        return cmd_ensure_project(args)
    if args.command == "bind-service":
        return cmd_bind_service(args)
    if args.command == "update-project":
        return cmd_update_project(args)
    if args.command == "update-unmanaged":
        return cmd_update_unmanaged(args)
    if args.command == "update-all":
        return cmd_update_all(args)
    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
