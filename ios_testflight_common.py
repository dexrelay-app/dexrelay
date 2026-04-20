from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any


def run(args: list[str], *, cwd: str | Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        cwd=str(cwd) if cwd is not None else None,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or f"Command failed: {' '.join(args)}"
        raise RuntimeError(message)
    return completed


def sanitize_component(value: str) -> str:
    normalized = re.sub(r"[^a-zA-Z0-9._-]+", "-", value.strip())
    normalized = re.sub(r"-{2,}", "-", normalized).strip("-")
    return normalized or "artifact"


def find_first_xcodeproj(root: Path) -> Path | None:
    for candidate in sorted(root.glob("*.xcodeproj")):
        return candidate
    for depth in range(1, 6):
        pattern = "*/" * depth + "*.xcodeproj"
        for candidate in sorted(root.glob(pattern)):
            return candidate
    return None


def detect_scheme(project_file: Path) -> str:
    listed = run(["xcodebuild", "-list", "-project", str(project_file)])
    capture = False
    for raw_line in listed.stdout.splitlines():
        line = raw_line.rstrip()
        if line.strip() == "Schemes:":
            capture = True
            continue
        if capture:
            if not line.strip():
                continue
            return line.strip()
    return project_file.stem


def parse_build_settings(project_file: Path, scheme: str) -> dict[str, Any]:
    listed = run(["xcodebuild", "-list", "-json", "-project", str(project_file)])
    project = (json.loads(listed.stdout).get("project") or {})
    targets = [str(target).strip() for target in (project.get("targets") or []) if str(target).strip()]
    rows: list[dict[str, Any]] = []
    seen_bundle_ids: set[str] = set()
    for target in targets:
        completed = run(
            [
                "xcodebuild",
                "-showBuildSettings",
                "-json",
                "-project",
                str(project_file),
                "-target",
                target,
                "-configuration",
                "Release",
            ]
        )
        payload = json.loads(completed.stdout)
        for item in payload:
            settings = item.get("buildSettings") or {}
            wrapper = str(settings.get("WRAPPER_EXTENSION") or "").strip()
            bundle_id = str(settings.get("PRODUCT_BUNDLE_IDENTIFIER") or "").strip()
            if wrapper not in {"app", "appex"} or not bundle_id or bundle_id in seen_bundle_ids:
                continue
            seen_bundle_ids.add(bundle_id)
            rows.append(
                {
                    "target": item.get("target") or target,
                    "wrapper": wrapper,
                    "bundle_id": bundle_id,
                    "product_name": str(settings.get("PRODUCT_NAME") or scheme).strip(),
                    "marketing_version": str(settings.get("MARKETING_VERSION") or "").strip(),
                    "build_number": str(settings.get("CURRENT_PROJECT_VERSION") or "").strip(),
                    "development_team": str(settings.get("DEVELOPMENT_TEAM") or "").strip(),
                }
            )
    app_rows = [row for row in rows if row["wrapper"] == "app"]
    if not app_rows:
        raise RuntimeError(f"No app target found in scheme {scheme}")
    return {"main": app_rows[0], "all": rows}


def parse_key_id(status_output: str) -> str | None:
    match = re.search(r"Key ID:\s*([A-Z0-9]+)", status_output)
    return match.group(1) if match else None


def locate_auth_key(key_id: str, start_dir: Path) -> Path | None:
    filename = f"AuthKey_{key_id}.p8"
    candidates = [
        start_dir,
        Path.home() / "Downloads",
        Path.home() / "Desktop",
        Path.home() / "Documents",
        Path.home() / ".asc",
        Path.home() / "src",
    ]
    for base in candidates:
        if not base.exists():
            continue
        if base.is_file() and base.name == filename:
            return base
        for path in base.rglob(filename):
            return path
    return None


def prepare_asc_cwd(project_dir: Path) -> tuple[Path | None, str | None]:
    status = run(["asc", "auth", "status"], cwd=project_dir)
    doctor = run(["asc", "auth", "doctor"], cwd=project_dir, check=False)
    if doctor.returncode == 0:
        return None, parse_key_id(status.stdout)

    key_id = parse_key_id(status.stdout)
    if not key_id:
        raise RuntimeError("asc auth is configured, but no App Store Connect key ID could be found")

    located = locate_auth_key(key_id, project_dir)
    if located is None:
        raise RuntimeError(f"asc auth doctor failed and AuthKey_{key_id}.p8 could not be found in common locations")

    temp_dir = Path(tempfile.mkdtemp(prefix="asc-auth-"))
    temp_key = temp_dir / f"AuthKey_{key_id}.p8"
    shutil.copy2(located, temp_key)
    os.chmod(temp_key, 0o600)

    doctor_retry = run(["asc", "auth", "doctor"], cwd=temp_dir, check=False)
    if doctor_retry.returncode != 0:
        details = doctor_retry.stderr.strip() or doctor_retry.stdout.strip() or "unknown auth doctor failure"
        raise RuntimeError(f"asc auth remains invalid after locating the key file: {details}")

    return temp_dir, key_id


def asc_json(args: list[str], *, cwd: Path) -> dict[str, Any]:
    completed = run(["asc", *args, "--output", "json"], cwd=cwd)
    return json.loads(completed.stdout)


def existing_bundle_ids(asc_cwd: Path) -> dict[str, str]:
    payload = asc_json(["bundle-ids", "list"], cwd=asc_cwd)
    mapping: dict[str, str] = {}
    for item in payload.get("data") or []:
        identifier = ((item.get("attributes") or {}).get("identifier") or "").strip()
        bundle_id = (item.get("id") or "").strip()
        if identifier and bundle_id:
            mapping[identifier] = bundle_id
    return mapping


def ensure_bundle_id(asc_cwd: Path, identifier: str, name: str, cached: dict[str, str]) -> tuple[str, str]:
    existing = cached.get(identifier)
    if existing:
        return existing, "existing"
    created = asc_json(
        ["bundle-ids", "create", "--identifier", identifier, "--name", name, "--platform", "IOS"],
        cwd=asc_cwd,
    )
    bundle_id = str((created.get("data") or {}).get("id") or "").strip()
    if not bundle_id:
        raise RuntimeError(f"Bundle ID creation did not return an ID for {identifier}")
    cached[identifier] = bundle_id
    return bundle_id, "created"


def resolve_app_record(asc_cwd: Path, bundle_id: str, explicit_app_id: str | None) -> tuple[str | None, dict[str, Any] | None]:
    if explicit_app_id:
        payload = asc_json(["apps", "view", "--id", explicit_app_id], cwd=asc_cwd)
        return explicit_app_id, payload.get("data")
    payload = asc_json(["apps", "list", "--bundle-id", bundle_id], cwd=asc_cwd)
    data = payload.get("data") or []
    if not data:
        return None, None
    app = data[0]
    return str(app.get("id") or "").strip() or None, app


def ensure_internal_groups(asc_cwd: Path, app_id: str, names: list[str]) -> list[dict[str, str]]:
    listed = run(["asc", "testflight", "groups", "list", "--app", app_id, "--output", "json"], cwd=asc_cwd, check=False)
    if listed.returncode == 0:
        payload = json.loads(listed.stdout)
        list_family = "groups"
    else:
        payload = asc_json(["testflight", "beta-groups", "list", "--app", app_id], cwd=asc_cwd)
        list_family = "beta-groups"
    existing: dict[str, str] = {}
    for item in payload.get("data") or []:
        group_name = ((item.get("attributes") or {}).get("name") or "").strip()
        group_id = (item.get("id") or "").strip()
        if group_name and group_id:
            existing[group_name] = group_id

    resolved: list[dict[str, str]] = []
    for name in names:
        group_id = existing.get(name)
        state = "existing"
        if not group_id:
            create_args = ["testflight", list_family, "create", "--app", app_id, "--name", name, "--internal"]
            created_run = run(["asc", *create_args, "--output", "json"], cwd=asc_cwd, check=False)
            if created_run.returncode == 0:
                created = json.loads(created_run.stdout)
            else:
                created = asc_json(["testflight", "beta-groups", "create", "--app", app_id, "--name", name, "--internal"], cwd=asc_cwd)
            group_id = str((created.get("data") or {}).get("id") or "").strip()
            if not group_id:
                raise RuntimeError(f"Could not create TestFlight beta group {name}")
            existing[name] = group_id
            state = "created"
        resolved.append({"name": name, "id": group_id, "state": state})
    return resolved


def fetch_signing_profiles(asc_cwd: Path, bundle_identifiers: list[str], output_root: Path) -> list[str]:
    warnings: list[str] = []
    for bundle_id in bundle_identifiers:
        bundle_output = output_root / sanitize_component(bundle_id)
        bundle_output.mkdir(parents=True, exist_ok=True)
        completed = run(
            [
                "asc",
                "signing",
                "fetch",
                "--bundle-id",
                bundle_id,
                "--profile-type",
                "IOS_APP_STORE",
                "--create-missing",
                "--output",
                str(bundle_output),
            ],
            cwd=asc_cwd,
            check=False,
        )
        if completed.returncode != 0:
            details = completed.stderr.strip() or completed.stdout.strip() or "unknown signing fetch failure"
            warnings.append(f"{bundle_id}: {details}")
    return warnings


def next_build_number(asc_cwd: Path, app_id: str, marketing_version: str, current_build: str) -> str | None:
    completed = run(
        [
            "asc",
            "builds",
            "next-build-number",
            "--app",
            app_id,
            "--version",
            marketing_version,
            "--platform",
            "IOS",
            "--initial-build-number",
            current_build or "1",
            "--output",
            "json",
        ],
        cwd=asc_cwd,
        check=False,
    )
    if completed.returncode != 0:
        return None
    payload = json.loads(completed.stdout)
    return str(payload.get("nextBuildNumber") or payload.get("next_build_number") or "").strip() or None


def latest_build(asc_cwd: Path, app_id: str, version: str) -> dict[str, Any] | None:
    completed = run(
        ["asc", "builds", "info", "--app", app_id, "--latest", "--version", version, "--platform", "IOS", "--output", "json"],
        cwd=asc_cwd,
        check=False,
    )
    if completed.returncode != 0:
        return None
    payload = json.loads(completed.stdout)
    return payload.get("data")


def ensure_encryption_declaration(asc_cwd: Path, app_id: str) -> str:
    payload = asc_json(["encryption", "declarations", "list", "--app", app_id], cwd=asc_cwd)
    declarations = payload.get("data") or []
    if declarations:
        declaration_id = str(declarations[0].get("id") or "").strip()
        if declaration_id:
            return declaration_id

    created = asc_json(
        [
            "encryption",
            "declarations",
            "create",
            "--app",
            app_id,
            "--app-description",
            "Uses standard Apple and third-party cryptography for secure network transport and authentication, including HTTPS/TLS and related security protocols. No proprietary cryptographic algorithms are implemented by the app.",
            "--contains-proprietary-cryptography=false",
            "--contains-third-party-cryptography=true",
            "--available-on-french-store=true",
        ],
        cwd=asc_cwd,
    )
    declaration_id = str((created.get("data") or {}).get("id") or "").strip()
    if not declaration_id:
        raise RuntimeError("Could not create encryption declaration")
    return declaration_id


def build_beta_detail_state(asc_cwd: Path, build_id: str) -> str | None:
    payload = asc_json(["builds", "build-beta-detail", "view", "--build-id", build_id], cwd=asc_cwd)
    data = payload.get("data") or {}
    attributes = data.get("attributes") or {}
    state = str(attributes.get("internalBuildState") or "").strip()
    return state or None


def assign_build_to_groups(asc_cwd: Path, build_id: str, group_ids: list[str]) -> None:
    if not group_ids:
        return
    run(["asc", "builds", "add-groups", "--build-id", build_id, "--group", ",".join(group_ids)], cwd=asc_cwd)


def assign_build_to_encryption_declaration(asc_cwd: Path, declaration_id: str, build_id: str) -> None:
    run(["asc", "encryption", "declarations", "assign-builds", "--id", declaration_id, "--build", build_id], cwd=asc_cwd)


def artifact_root(project_dir: Path, scheme: str) -> Path:
    return project_dir / ".asc-artifacts" / "testflight" / sanitize_component(scheme) / "latest"


def write_artifact_metadata(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def load_artifact_metadata(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    return json.loads(path.read_text())
