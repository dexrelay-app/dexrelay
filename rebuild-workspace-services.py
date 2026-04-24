#!/usr/bin/env python3
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shlex
import subprocess
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    tomllib = None

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
SERVICECTL_PATH = SCRIPT_DIR / "servicectl.py"
GOVERNANCECTL_PATH = SCRIPT_DIR / "governancectl.py"
REGISTRY_PATH = SCRIPT_DIR / "services.registry.json"
DEFAULT_BASE_DIR = Path(os.environ.get("CODEX_RELAY_PROJECTS_ROOT", str(Path.home() / "src"))).expanduser()

COMMON_SHELL_STARTERS = (
    "start_backend.sh",
    "start-backend.sh",
    "start_server.sh",
    "start-server.sh",
    "start.sh",
)
COMMON_SERVICE_DIRS = ("backend", "server", "api", "services", "svc", "")
COMMON_NODE_SCRIPTS = ("start:safe", "start", "serve", "dev")
PORT_PATTERNS = (
    re.compile(r"--port\s+(\d{4,5})"),
    re.compile(r"\bPORT\s*[:=]\s*['\"]?(\d{4,5})", re.IGNORECASE),
    re.compile(r"127\.0\.0\.1:(\d{4,5})"),
    re.compile(r"localhost:(\d{4,5})"),
)
IGNORED_PROJECT_PATTERNS = (
    ".",
    "__",
)
IGNORED_PROJECT_SUBSTRINGS = (
    ".backup-",
    ".bak-",
)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def run_shell(command: str, *, timeout: int = 120) -> dict[str, Any]:
    completed = subprocess.run(
        ["/bin/zsh", "-lc", command],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return {
        "exitCode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
        "command": command,
    }


def slugify(value: str) -> str:
    out: list[str] = []
    previous_dash = False
    for character in value.lower():
        if character.isalnum():
            out.append(character)
            previous_dash = False
        else:
            if not previous_dash:
                out.append("-")
                previous_dash = True
    text = "".join(out).strip("-")
    return text or "project"


def shell_quote(value: str) -> str:
    return shlex.quote(value)


def load_registry(path: Path = REGISTRY_PATH) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "portPolicy": {"min": 8000, "max": 8999, "reserved": [4500, 4600, 4610, 4615, 4616]}, "services": []}
    data = load_json(path)
    if not isinstance(data, dict):
        raise ValueError(f"invalid registry root: {path}")
    data.setdefault("version", 1)
    data.setdefault("portPolicy", {})
    data.setdefault("services", [])
    return data


def normalize_registry_service(raw: dict[str, Any]) -> dict[str, Any]:
    exposure_raw = raw.get("exposure", {})
    exposure = exposure_raw if isinstance(exposure_raw, dict) else {}
    return {
        "id": str(raw.get("id") or raw.get("serviceId") or "").strip(),
        "name": str(raw.get("name") or "").strip(),
        "projectPath": str(raw.get("projectPath") or "").strip(),
        "healthCheck": str(raw.get("healthCheck") or "").strip(),
        "startCommand": str(raw.get("startCommand") or "").strip(),
        "stopCommand": str(raw.get("stopCommand") or "").strip(),
        "restartCommand": str(raw.get("restartCommand") or "").strip(),
        "ports": [port for port in raw.get("ports", []) if isinstance(port, int)],
        "tags": [str(tag).strip() for tag in raw.get("tags", []) if str(tag).strip()],
        "openPath": str(raw.get("openPath") or "").strip(),
        "exposure": {
            "mode": str(exposure.get("mode") or "").strip(),
            "path": str(exposure.get("path") or "").strip(),
            "target": str(exposure.get("target") or "").strip(),
        },
    }


def service_score(service: dict[str, Any]) -> int:
    score = 0
    for key in ("name", "projectPath", "healthCheck", "startCommand", "stopCommand", "restartCommand", "openPath"):
        if str(service.get(key) or "").strip():
            score += 1
    score += len(service.get("ports", [])) * 2
    score += len(service.get("tags", []))
    exposure = service.get("exposure", {})
    if isinstance(exposure, dict):
        for key in ("mode", "path", "target"):
            if str(exposure.get(key) or "").strip():
                score += 1
    return score


def merge_service_rows(service_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    for raw in service_rows:
        service = normalize_registry_service(raw)
        service_id = service["id"]
        if not service_id:
            continue
        existing = merged.get(service_id)
        if existing is None or service_score(service) >= service_score(existing):
            merged[service_id] = service
    return sorted(merged.values(), key=lambda item: item["id"])


def codex_config_project_paths(config_path: Path) -> list[Path]:
    if not config_path.exists():
        return []
    if tomllib is not None:
        try:
            config = tomllib.loads(config_path.read_text(encoding="utf-8"))
            config_projects = config.get("projects", {})
            if isinstance(config_projects, dict):
                return [Path(raw_path) for raw_path in config_projects.keys()]
        except Exception:
            return []

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
    return paths


def discover_projects(base_dir: Path) -> list[Path]:
    discovered: list[Path] = []

    def add_project(path: Path) -> None:
        if not path.is_dir():
            return
        try:
            candidate = path.expanduser().resolve()
        except OSError:
            candidate = path.expanduser()
        name = candidate.name
        lowered = name.lower()
        if any(lowered.startswith(prefix) for prefix in IGNORED_PROJECT_PATTERNS):
            return
        if any(token in lowered for token in IGNORED_PROJECT_SUBSTRINGS):
            return
        if candidate not in discovered:
            discovered.append(candidate)

    if base_dir.exists():
        for child in base_dir.iterdir():
            add_project(child)

    config_path = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "config.toml"
    for raw_path in codex_config_project_paths(config_path):
        add_project(raw_path)

    return sorted(discovered, key=lambda path: path.name.lower())


def candidate_seed_registry_paths(base_dir: Path) -> list[Path]:
    paths: list[Path] = []
    for project_path in discover_projects(base_dir):
        candidate = project_path / "scripts" / "services.registry.json"
        if candidate.exists():
            paths.append(candidate)
    return paths


def load_seed_services(base_dir: Path) -> tuple[list[dict[str, Any]], list[str]]:
    imported: list[dict[str, Any]] = []
    imported_paths: list[str] = []
    for registry_path in candidate_seed_registry_paths(base_dir):
        try:
            payload = load_registry(registry_path)
        except Exception:
            continue
        rows = [normalize_registry_service(row) for row in payload.get("services", []) if isinstance(row, dict)]
        if not rows:
            continue
        imported.extend(rows)
        imported_paths.append(str(registry_path))
    return imported, imported_paths


def load_project_governance_services(base_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for project_path in discover_projects(base_dir):
        governance_path = project_path / ".dexrelay" / "project-governance.json"
        if not governance_path.exists():
            continue
        try:
            payload = load_json(governance_path)
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        for raw in payload.get("services", []):
            if isinstance(raw, dict):
                service = dict(raw)
                service.setdefault("projectPath", str(project_path))
                rows.append(normalize_registry_service(service))
    return rows


def collect_search_files(project_path: Path, start_dir: Path) -> list[Path]:
    candidates: list[Path] = []
    preferred = [
        start_dir / ".env",
        start_dir / ".env.local",
        start_dir / "package.json",
        start_dir / "pyproject.toml",
        start_dir / "requirements.txt",
    ]
    for path in preferred:
        if path.exists():
            candidates.append(path)

    for glob_pattern in ("*.py", "*.js", "*.ts", "*.tsx", "*.sh"):
        for path in sorted(start_dir.glob(glob_pattern))[:6]:
            if path not in candidates:
                candidates.append(path)

    if start_dir != project_path:
        for path in (project_path / ".env", project_path / ".env.local", project_path / "package.json", project_path / "pyproject.toml"):
            if path.exists() and path not in candidates:
                candidates.append(path)
    return candidates[:18]


def find_port_in_files(paths: list[Path]) -> int | None:
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for pattern in PORT_PATTERNS:
            match = pattern.search(text)
            if not match:
                continue
            port = int(match.group(1))
            if 1024 <= port <= 65535:
                return port
    return None


def build_port_actions(service_slug: str, directory: Path, starter: str, port: int) -> dict[str, str]:
    log_path = f"/tmp/{service_slug}.log"
    start = (
        f"cd {shell_quote(str(directory))} && "
        f"nohup {starter} >{shell_quote(log_path)} 2>&1 < /dev/null &"
    )
    stop = f"pids=$(lsof -ti tcp:{port} 2>/dev/null || true); if [ -n \"$pids\" ]; then kill -9 $pids; fi"
    restart = f"{stop}; cd {shell_quote(str(directory))} && nohup {starter} >{shell_quote(log_path)} 2>&1 < /dev/null &"
    health = f"curl -fsS http://127.0.0.1:{port}/health >/dev/null 2>&1 || lsof -nP -iTCP:{port} -sTCP:LISTEN >/dev/null 2>&1"
    return {
        "startCommand": start,
        "stopCommand": stop,
        "restartCommand": restart,
        "healthCheck": health,
    }


def infer_shell_service(project_path: Path, used_service_ids: set[str], used_ports: set[int]) -> tuple[dict[str, Any] | None, str | None]:
    for directory_name in COMMON_SERVICE_DIRS:
        directory = project_path / directory_name if directory_name else project_path
        if not directory.exists() or not directory.is_dir():
            continue
        for filename in COMMON_SHELL_STARTERS:
            script_path = directory / filename
            if not script_path.exists():
                continue
            port = find_port_in_files(collect_search_files(project_path, directory) + [script_path])
            if port is None:
                return None, f"found {script_path.relative_to(project_path)} but no explicit port"
            if port in used_ports:
                return None, f"detected port {port} for {script_path.relative_to(project_path)} but that port is already claimed"
            service_slug = slugify(project_path.name)
            service_id = f"{service_slug}-backend"
            suffix = 2
            while service_id in used_service_ids:
                service_id = f"{service_slug}-backend-{suffix}"
                suffix += 1
            actions = build_port_actions(service_slug, directory, f"./{script_path.name}", port)
            return {
                "id": service_id,
                "name": f"{project_path.name} backend",
                "projectPath": str(project_path),
                "ports": [port],
                "tags": ["backend", "inferred", "shell"],
                **actions,
            }, None
    return None, None


def infer_node_service(project_path: Path, used_service_ids: set[str], used_ports: set[int]) -> tuple[dict[str, Any] | None, str | None]:
    for directory_name in COMMON_SERVICE_DIRS:
        directory = project_path / directory_name if directory_name else project_path
        package_path = directory / "package.json"
        if not package_path.exists():
            continue
        try:
            payload = json.loads(package_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        scripts = payload.get("scripts", {})
        if not isinstance(scripts, dict):
            continue
        script_name = next((name for name in COMMON_NODE_SCRIPTS if isinstance(scripts.get(name), str) and scripts.get(name, "").strip()), None)
        if script_name is None:
            continue
        port = find_port_in_files(collect_search_files(project_path, directory))
        if port is None:
            return None, f"found package.json in {directory.relative_to(project_path) or Path('.')} but no explicit port"
        if port in used_ports:
            return None, f"detected port {port} in {directory.relative_to(project_path) or Path('.')} but that port is already claimed"
        service_slug = slugify(project_path.name)
        service_id = f"{service_slug}-backend"
        suffix = 2
        while service_id in used_service_ids:
            service_id = f"{service_slug}-backend-{suffix}"
            suffix += 1
        actions = build_port_actions(service_slug, directory, f"npm run {script_name}", port)
        return {
            "id": service_id,
            "name": f"{project_path.name} backend",
            "projectPath": str(project_path),
            "ports": [port],
            "tags": ["backend", "inferred", "node"],
            **actions,
        }, None
    return None, None


def infer_missing_services(base_dir: Path, existing_services: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    inferred: list[dict[str, Any]] = []
    notes: list[dict[str, str]] = []
    projects_with_services = {str(Path(service["projectPath"])) for service in existing_services if service.get("projectPath") not in {"", "*"}}
    used_service_ids = {service["id"] for service in existing_services if service.get("id")}
    used_ports = {port for service in existing_services for port in service.get("ports", []) if isinstance(port, int)}

    for project_path in discover_projects(base_dir):
        normalized = str(project_path)
        if normalized in projects_with_services:
            continue
        service, note = infer_shell_service(project_path, used_service_ids, used_ports)
        if service is None:
            service, node_note = infer_node_service(project_path, used_service_ids, used_ports)
            note = note or node_note
        if service is None:
            if note:
                notes.append({"projectPath": normalized, "reason": note})
            continue
        inferred.append(service)
        projects_with_services.add(normalized)
        used_service_ids.add(service["id"])
        used_ports.update(service.get("ports", []))
    return inferred, notes


def union_port_policy(current: dict[str, Any], seed_payloads: list[dict[str, Any]]) -> dict[str, Any]:
    policies = [current.get("portPolicy", {})]
    policies.extend(payload.get("portPolicy", {}) for payload in seed_payloads)
    min_port = 8000
    max_port = 8999
    reserved: set[int] = set()
    for policy in policies:
        if not isinstance(policy, dict):
            continue
        if isinstance(policy.get("min"), int):
            min_port = min(min_port, int(policy["min"]))
        if isinstance(policy.get("max"), int):
            max_port = max(max_port, int(policy["max"]))
        reserved.update(int(port) for port in policy.get("reserved", []) if isinstance(port, int))
    return {
        "min": min_port,
        "max": max_port,
        "reserved": sorted(reserved),
    }


def servicectl_json(*args: str, timeout: int = 180) -> dict[str, Any]:
    command = ["python3", str(SERVICECTL_PATH), *args, "--json"]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    stdout = completed.stdout.strip()
    payload: dict[str, Any] = {"ok": completed.returncode == 0, "exitCode": completed.returncode}
    if stdout:
        try:
            parsed = json.loads(stdout)
            if isinstance(parsed, dict):
                payload.update(parsed)
        except json.JSONDecodeError:
            payload["stdout"] = stdout
    stderr = completed.stderr.strip()
    if stderr:
        payload["stderr"] = stderr
    return payload


def governance_json(*args: str, timeout: int = 180) -> dict[str, Any]:
    command = ["python3", str(GOVERNANCECTL_PATH), *args, "--json"]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    stdout = completed.stdout.strip()
    payload: dict[str, Any] = {"ok": completed.returncode == 0, "exitCode": completed.returncode}
    if stdout:
        try:
            parsed = json.loads(stdout)
            if isinstance(parsed, dict):
                payload.update(parsed)
        except json.JSONDecodeError:
            payload["stdout"] = stdout
    stderr = completed.stderr.strip()
    if stderr:
        payload["stderr"] = stderr
    return payload


def publish_tailscale_path(path: str, target: str) -> tuple[bool, str]:
    command = [
        "/Applications/Tailscale.app/Contents/MacOS/tailscale",
        "serve",
        "--bg",
        "--yes",
        "--set-path",
        path,
        target,
    ]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=20)
    except FileNotFoundError:
        return False, "Tailscale CLI not found"
    output = ((completed.stdout or "") + (completed.stderr or "")).strip()
    return completed.returncode == 0, output or ("published" if completed.returncode == 0 else f"tailscale serve failed with exit {completed.returncode}")


def start_and_publish_services() -> dict[str, Any]:
    listed = servicectl_json("list", timeout=120)
    rows = listed.get("services", []) if isinstance(listed.get("services"), list) else []
    started: list[dict[str, Any]] = []
    failed: list[dict[str, Any]] = []
    published: list[dict[str, Any]] = []
    start_candidates: list[str] = []
    start_results: dict[str, dict[str, Any]] = {}

    for row in rows:
        if not isinstance(row, dict):
            continue
        project_path = str(row.get("projectPath") or "").strip()
        service_id = str(row.get("id") or row.get("serviceId") or "").strip()
        if not service_id or project_path in {"", "*"}:
            continue
        if not bool(row.get("running")):
            start_candidates.append(service_id)

    if start_candidates:
        max_workers = min(6, max(1, len(start_candidates)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
            future_map = {
                executor.submit(servicectl_json, "start", service_id, timeout=25): service_id
                for service_id in start_candidates
            }
            for future in concurrent.futures.as_completed(future_map):
                service_id = future_map[future]
                try:
                    action = future.result()
                except Exception as exc:
                    failed.append({"serviceId": service_id, "error": f"start failed: {exc}"})
                    continue
                start_results[service_id] = action

    refreshed = servicectl_json("list", timeout=120)
    rows = refreshed.get("services", []) if isinstance(refreshed.get("services"), list) else []
    refreshed_by_id = {
        str(row.get("id") or row.get("serviceId") or "").strip(): row
        for row in rows
        if isinstance(row, dict)
    }

    for service_id in start_candidates:
        action = start_results.get(service_id, {})
        refreshed_row = refreshed_by_id.get(service_id, {})
        if bool(refreshed_row.get("running")):
            started.append({"serviceId": service_id, "message": str(action.get("message") or "started")})
            continue
        error = (
            str(action.get("message") or "").strip()
            or str(action.get("stderr") or "").strip()
            or "service did not come up"
        )
        failed.append({"serviceId": service_id, "error": error})

    for row in rows:
        if not isinstance(row, dict) or not bool(row.get("running")):
            continue
        service_id = str(row.get("id") or row.get("serviceId") or "").strip()
        exposure = row.get("exposure", {})
        if not isinstance(exposure, dict):
            continue
        if str(exposure.get("mode") or "").strip() != "tailscale-serve":
            continue
        exposure_path = str(exposure.get("path") or "").strip()
        if not exposure_path:
            continue
        ports = [port for port in row.get("ports", []) if isinstance(port, int)]
        target = str(exposure.get("target") or "").strip()
        if not target and ports:
            target = f"http://127.0.0.1:{ports[0]}"
        if not target:
            failed.append({"serviceId": service_id, "error": "missing Tailscale target"})
            continue
        normalized_path = exposure_path if exposure_path.startswith("/") else "/" + exposure_path
        ok, detail = publish_tailscale_path(normalized_path, target)
        if ok:
            published.append({"serviceId": service_id, "path": normalized_path, "target": target, "detail": detail})
        else:
            failed.append({"serviceId": service_id, "error": detail})

    return {
        "ok": len(failed) == 0,
        "started": started,
        "failed": failed,
        "published": published,
    }


def rebuild_workspace(base_dir: Path, *, start_services: bool, publish_tailscale: bool) -> dict[str, Any]:
    current_registry = load_registry(REGISTRY_PATH)
    current_services = [normalize_registry_service(row) for row in current_registry.get("services", []) if isinstance(row, dict)]
    seed_services, imported_paths = load_seed_services(base_dir)
    seed_payloads = [load_registry(Path(path)) for path in imported_paths]
    governance_services = load_project_governance_services(base_dir)
    merged_before_inference = merge_service_rows(current_services + seed_services + governance_services)
    inferred_services, inference_notes = infer_missing_services(base_dir, merged_before_inference)
    merged_services = merge_service_rows(merged_before_inference + inferred_services)

    new_registry = {
        "version": current_registry.get("version", 1),
        "portPolicy": union_port_policy(current_registry, seed_payloads),
        "services": merged_services,
    }
    registry_changed = new_registry != current_registry
    if registry_changed:
        save_json(REGISTRY_PATH, new_registry)

    validate_result = servicectl_json("validate", timeout=60)
    sync_result = servicectl_json("sync-conf", timeout=60) if bool(validate_result.get("ok")) else {"ok": False, "error": "registry validation failed"}
    governance_result = governance_json("update-all", timeout=180)

    actions: dict[str, Any] = {"ok": True, "started": [], "failed": [], "published": []}
    if start_services or publish_tailscale:
        actions = start_and_publish_services()

    return {
        "ok": bool(validate_result.get("ok")) and bool(sync_result.get("ok")) and bool(governance_result.get("ok")) and bool(actions.get("ok")),
        "baseDir": str(base_dir),
        "registryPath": str(REGISTRY_PATH),
        "registryChanged": registry_changed,
        "serviceCount": len(merged_services),
        "importedRegistryPaths": imported_paths,
        "importedServiceCount": len(seed_services),
        "governanceServiceCount": len(governance_services),
        "inferredServiceCount": len(inferred_services),
        "inferredServices": inferred_services,
        "inferenceNotes": inference_notes,
        "validate": validate_result,
        "sync": sync_result,
        "governance": governance_result,
        "actions": actions if (start_services or publish_tailscale) else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Rebuild DexRelay workspace services from durable project and registry sources.")
    parser.add_argument("--base-dir", default=str(DEFAULT_BASE_DIR))
    parser.add_argument("--start-services", action="store_true")
    parser.add_argument("--publish-tailscale", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    payload = rebuild_workspace(
        Path(args.base_dir).expanduser(),
        start_services=args.start_services,
        publish_tailscale=args.publish_tailscale,
    )
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=False))
    else:
        print(f"workspace rebuilt: services={payload['serviceCount']} inferred={payload['inferredServiceCount']}")
        if payload["importedRegistryPaths"]:
            print("imported registries:")
            for path in payload["importedRegistryPaths"]:
                print(f"- {path}")
        if payload["inferenceNotes"]:
            print("projects still needing backend hints:")
            for row in payload["inferenceNotes"][:12]:
                print(f"- {row['projectPath']}: {row['reason']}")
        if payload.get("actions"):
            print(json.dumps(payload["actions"], indent=2))
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
