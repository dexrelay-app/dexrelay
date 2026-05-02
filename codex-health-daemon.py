#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shlex
import socket
import subprocess
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = PROJECT_ROOT / "scripts"
UI_DIR = PROJECT_ROOT / "health-ui"
COMMAND_CENTER_DIR = PROJECT_ROOT / "command-center"
PROJECTS_ROOT = Path(os.environ.get("CODEX_RELAY_PROJECTS_ROOT", str(Path.home() / "src"))).expanduser()
PORT = int(os.environ.get("CODEX_HEALTH_PORT", "4610"))
HOST = os.environ.get("CODEX_HEALTH_HOST", "0.0.0.0")
UID = os.getuid()
GUI_DOMAIN = f"gui/{UID}"
USER_DOMAIN = f"user/{UID}"
BRIDGE_LABEL = os.environ.get("CODEX_RELAY_LABEL", "com.codexrelay.bootstrap")
HELPER_LABEL = os.environ.get("CODEX_RELAY_HELPER_LABEL", "com.codexrelay.setuphelper")
HEALTHD_LABEL = os.environ.get("CODEX_RELAY_HEALTHD_LABEL", "com.codexrelay.healthd")
RELAY_SERVER_LABEL = os.environ.get("CODEX_RELAY_RELAY_SERVER_LABEL", "com.codexrelay.relayserver.bootstrap")
RELAY_CONNECTOR_LABEL = os.environ.get("CODEX_RELAY_RELAY_CONNECTOR_LABEL", "com.codexrelay.relayconnector.bootstrap")
BRIDGE_PORT = int(os.environ.get("CODEX_RELAY_BRIDGE_PORT", "4615"))
HELPER_PORT = int(os.environ.get("CODEX_RELAY_HELPER_PORT", "4616"))
RELAY_SERVER_PORT = int(os.environ.get("CODEX_RELAY_RELAY_SERVER_PORT", "4620"))
DEFAULT_PROJECT = str(PROJECTS_ROOT)
SERVICECTL_SCRIPT = SCRIPT_DIR / "servicectl.py"
GOVERNANCECTL_SCRIPT = SCRIPT_DIR / "governancectl.py"
CODEX_FAST_SCRIPT = SCRIPT_DIR / "codex-fast.py"
if not CODEX_FAST_SCRIPT.exists():
    CODEX_FAST_SCRIPT = Path(__file__).resolve().with_name("codex-fast.py")
DISCOVERED_PROJECTS_PATH = COMMAND_CENTER_DIR / "discovered-projects.json"
GOVERNANCE_SUMMARY_PATH = COMMAND_CENTER_DIR / "codex-governance.json"
IGNORED_PROJECT_DIRS = {
    ".git", ".build", ".idea", ".next", ".swiftpm", ".venv", "DerivedData", "Pods",
    "build", "dist", "node_modules", "out", "target", "venv",
}
CODE_FILE_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".css", ".go", ".h", ".hpp", ".html", ".java", ".js", ".json",
    ".kt", ".kts", ".m", ".md", ".mm", ".php", ".py", ".rb", ".rs", ".scss", ".sh",
    ".sql", ".swift", ".toml", ".ts", ".tsx", ".txt", ".xml", ".yaml", ".yml",
}


def run_shell(command: str, *, cwd: str | Path | None = None, timeout: int = 30, env: dict[str, str] | None = None) -> dict[str, object]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    completed = subprocess.run(
        ["/bin/zsh", "-lc", command],
        cwd=str(cwd or PROJECT_ROOT),
        capture_output=True,
        text=True,
        timeout=timeout,
        env=merged_env,
    )
    return {"exitCode": completed.returncode, "stdout": completed.stdout, "stderr": completed.stderr}


def check_port(port: int, host: str = "127.0.0.1") -> bool:
    with socket.socket() as sock:
        sock.settimeout(1.5)
        return sock.connect_ex((host, port)) == 0


def command_for_port(port: int) -> str:
    result = run_shell(f"lsof -nP -iTCP:{port} -sTCP:LISTEN -Fpcn | tr '\\n' ' '", timeout=5)
    text = ((result.get("stdout") or "") + " " + (result.get("stderr") or "")).strip()
    return text or "Unavailable"


def launchd_loaded(label: str) -> bool:
    for domain in (GUI_DOMAIN, USER_DOMAIN):
        probe = subprocess.run(["launchctl", "print", f"{domain}/{label}"], capture_output=True, text=True)
        if probe.returncode == 0:
            return True
    return False


def tailscale_ip() -> str | None:
    result = run_shell("ifconfig | awk '/inet 100\\./ {print $2; exit}'", timeout=5)
    value = (result.get("stdout") or "").strip()
    return value or None


def xcode_running() -> bool:
    return int(run_shell("pgrep -x Xcode >/dev/null 2>&1", timeout=5)["exitCode"]) == 0


def known_projects() -> list[dict[str, str]]:
    projects: list[dict[str, str]] = []
    seen: set[str] = set()
    if PROJECTS_ROOT.exists():
        for child in sorted(PROJECTS_ROOT.iterdir(), key=lambda item: item.name.lower()):
            if not child.is_dir():
                continue
            path = str(child)
            if path in seen:
                continue
            seen.add(path)
            projects.append({"path": path, "name": child.name})
    return projects


def project_metrics(project_path: str) -> dict[str, object]:
    path = Path(project_path).expanduser()
    if not path.exists() or not path.is_dir():
        return {"ok": False, "error": f"project not found: {project_path}"}

    file_count = 0
    code_file_count = 0
    line_count = 0

    for root, dirs, files in os.walk(path):
        dirs[:] = [entry for entry in dirs if entry not in IGNORED_PROJECT_DIRS]
        for name in files:
            file_count += 1
            candidate = Path(root) / name
            if candidate.suffix.lower() not in CODE_FILE_EXTENSIONS:
                continue
            code_file_count += 1
            try:
                with candidate.open("r", encoding="utf-8", errors="ignore") as handle:
                    line_count += sum(1 for _ in handle)
            except OSError:
                continue

    return {
        "ok": True,
        "projectPath": str(path),
        "fileCount": file_count,
        "codeFileCount": code_file_count,
        "lineCount": line_count,
    }


def gather_status() -> dict[str, object]:
    relay_port_open = check_port(BRIDGE_PORT)
    helper_port_open = check_port(HELPER_PORT)
    health_port_open = check_port(PORT)
    relay_server_open = check_port(RELAY_SERVER_PORT)
    ip = tailscale_ip()
    checks = [
        {
            "id": "tailscale",
            "name": "Tailscale link",
            "status": "ok" if ip else "failed",
            "detail": f"Mac Tailscale IP: {ip}" if ip else "No 100.x tailnet address found on this Mac.",
        },
        {
            "id": "healthd",
            "name": "Health daemon",
            "status": "ok" if health_port_open else "failed",
            "detail": f"HTTP health daemon listening on {HOST}:{PORT}." if health_port_open else f"Health daemon is not reachable on port {PORT}.",
        },
        {
            "id": "bridge",
            "name": "DexRelay bridge",
            "status": "ok" if relay_port_open and launchd_loaded(BRIDGE_LABEL) else "failed",
            "detail": f"Bridge is listening on port {BRIDGE_PORT}. {command_for_port(BRIDGE_PORT)}" if relay_port_open else f"Bridge is not listening on port {BRIDGE_PORT}.",
        },
        {
            "id": "helper",
            "name": "Setup helper",
            "status": "ok" if helper_port_open and launchd_loaded(HELPER_LABEL) else "failed",
            "detail": f"Setup helper is listening on port {HELPER_PORT}." if helper_port_open else f"Setup helper is not listening on port {HELPER_PORT}.",
        },
        {
            "id": "relay_server",
            "name": "Relay server",
            "status": "ok" if relay_server_open and launchd_loaded(RELAY_SERVER_LABEL) else "warn",
            "detail": f"Relay server is listening on port {RELAY_SERVER_PORT}." if relay_server_open else f"Relay server is not listening on port {RELAY_SERVER_PORT}.",
        },
        {
            "id": "xcode",
            "name": "Xcode",
            "status": "ok" if xcode_running() else "warn",
            "detail": "Xcode is already running." if xcode_running() else "Xcode is not open on the Mac.",
        },
    ]
    summary = "ok"
    if any(check["status"] == "failed" for check in checks):
        summary = "failed"
    elif any(check["status"] == "warn" for check in checks):
        summary = "warn"
    return {
        "summary": summary,
        "tailscaleIP": ip,
        "relayEndpoint": f"ws://{ip}:{BRIDGE_PORT}" if ip else None,
        "healthURL": f"http://{ip}:{PORT}" if ip else None,
        "checks": checks,
        "projects": known_projects(),
    }


def parse_body(handler: BaseHTTPRequestHandler) -> dict[str, object]:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        return {}
    raw = handler.rfile.read(length)
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        return {}


def action_response(name: str, result: dict[str, object]) -> dict[str, object]:
    return {
        "action": name,
        "ok": int(result.get("exitCode", 1)) == 0,
        "exitCode": result.get("exitCode", 1),
        "stdout": result.get("stdout", ""),
        "stderr": result.get("stderr", ""),
        "status": gather_status(),
    }


def parse_codex_fast_output(text: str) -> dict[str, object]:
    metrics: dict[str, object] = {}
    large_sessions: list[dict[str, object]] = []
    node_processes: list[dict[str, object]] = []
    blocking_processes: list[str] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        key = parts[0]
        if key == "large_session_mb" and len(parts) >= 3:
            try:
                large_sessions.append({"mb": float(parts[1]), "label": parts[2]})
            except ValueError:
                pass
            continue
        if key == "node_mb" and len(parts) >= 2:
            try:
                node_processes.append({"mb": float(parts[1]), "process": " ".join(parts[2:]) or "node"})
            except ValueError:
                pass
            continue
        if key == "blocking_process" and len(parts) >= 2:
            blocking_processes.append(" ".join(parts[1:]))
            continue
        if len(parts) >= 2:
            value = " ".join(parts[1:])
            try:
                if "." in value and value.replace(".", "", 1).isdigit():
                    metrics[key] = float(value)
                elif value.lstrip("-").isdigit():
                    metrics[key] = int(value)
                else:
                    metrics[key] = value
            except ValueError:
                metrics[key] = value

    return {
        "metrics": metrics,
        "largeSessions": large_sessions,
        "nodeProcesses": node_processes,
        "blockingProcesses": blocking_processes,
    }


def codex_fast_recommendations(parsed: dict[str, object]) -> list[dict[str, str]]:
    metrics = parsed.get("metrics") if isinstance(parsed.get("metrics"), dict) else {}
    recommendations: list[dict[str, str]] = []
    old_sessions = int(metrics.get("old_session_candidates") or 0)
    logs_mb = float(metrics.get("logs_mb") or 0)
    config_prune = int(metrics.get("config_prune_candidates") or 0)
    worktrees = int(metrics.get("worktree_candidates") or 0)
    if old_sessions > 0:
        recommendations.append({
            "title": "Archive old Codex sessions",
            "impact": "Can reduce heavy resume/history scans. Important active work should get a handoff first.",
            "severity": "warn" if old_sessions < 50 else "high",
        })
    if logs_mb >= 64:
        recommendations.append({
            "title": "Rotate large Codex logs",
            "impact": "Can reduce local database/file churn from oversized logs. Logs are archived, not deleted.",
            "severity": "warn" if logs_mb < 512 else "high",
        })
    if config_prune > 0:
        recommendations.append({
            "title": "Prune dead Codex project entries",
            "impact": "Removes stale project references so Codex has fewer irrelevant local paths to consider.",
            "severity": "warn",
        })
    if worktrees > 0:
        recommendations.append({
            "title": "Move stale worktrees",
            "impact": "Keeps old temporary worktrees out of the hot path while preserving them in an archive.",
            "severity": "warn",
        })
    if not recommendations:
        recommendations.append({
            "title": "Codex local state looks lean",
            "impact": "No obvious session/log/worktree cleanup candidate was found.",
            "severity": "ok",
        })
    return recommendations


def codex_fast_command(mode: str, *, wait_for_codex_exit: bool = False) -> dict[str, object]:
    if not CODEX_FAST_SCRIPT.exists():
        return {"ok": False, "error": f"missing {CODEX_FAST_SCRIPT}"}
    args = ""
    if mode == "backup":
        args = "--backup-only"
    elif mode == "apply":
        args = "--apply"
        if wait_for_codex_exit:
            args += " --wait-for-codex-exit"
    elif mode != "report":
        return {"ok": False, "error": f"unsupported codex-fast mode: {mode}"}

    result = run_shell(f"python3 {shlex.quote(str(CODEX_FAST_SCRIPT))} {args}".strip(), timeout=240)
    stdout = str(result.get("stdout", "") or "")
    stderr = str(result.get("stderr", "") or "")
    parsed = parse_codex_fast_output(stdout)
    return {
        "ok": int(result.get("exitCode", 1)) == 0,
        "mode": mode,
        "exitCode": result.get("exitCode", 1),
        "stdout": stdout,
        "stderr": stderr,
        "summary": parsed,
        "recommendations": codex_fast_recommendations(parsed),
        "status": gather_status(),
    }


def list_services() -> dict[str, object]:
    if not SERVICECTL_SCRIPT.exists():
        return {"ok": False, "error": f"missing {SERVICECTL_SCRIPT}"}
    result = run_shell(f"python3 {shlex.quote(str(SERVICECTL_SCRIPT))} list --json", timeout=40)
    if int(result.get("exitCode", 1)) != 0:
        return {"ok": False, "error": "servicectl list failed", "stdout": result.get("stdout", ""), "stderr": result.get("stderr", "")}
    try:
        payload = json.loads(str(result.get("stdout", "") or "{}"))
        if isinstance(payload, dict):
            return payload
    except json.JSONDecodeError:
        pass
    return {"ok": False, "error": "invalid servicectl list output"}


def run_servicectl_action(service_id: str, action: str) -> dict[str, object]:
    if not SERVICECTL_SCRIPT.exists():
        return {"ok": False, "error": f"missing {SERVICECTL_SCRIPT}"}
    result = run_shell(f"python3 {shlex.quote(str(SERVICECTL_SCRIPT))} {action} {shlex.quote(service_id)} --json", timeout=120)
    try:
        payload = json.loads(str(result.get("stdout", "") or "{}"))
        if isinstance(payload, dict):
            payload.setdefault("ok", int(result.get("exitCode", 1)) == 0)
            return payload
    except json.JSONDecodeError:
        pass
    return {"ok": int(result.get("exitCode", 1)) == 0, "stdout": result.get("stdout", ""), "stderr": result.get("stderr", "")}


def governance_command(subcommand: str, *, body: dict[str, object] | None = None, timeout: int = 180) -> dict[str, object]:
    if not GOVERNANCECTL_SCRIPT.exists():
        return {"ok": False, "error": f"missing {GOVERNANCECTL_SCRIPT}"}
    command = ["python3", shlex.quote(str(GOVERNANCECTL_SCRIPT)), subcommand]
    payload_body = body or {}
    if subcommand == "update-project":
        project_path = str(payload_body.get("projectPath") or "").strip()
        if not project_path:
            return {"ok": False, "error": "projectPath is required"}
        command.extend(["--project-path", shlex.quote(project_path)])
        project_name = str(payload_body.get("projectName") or "").strip()
        if project_name:
            command.extend(["--project-name", shlex.quote(project_name)])
    elif subcommand == "reconcile":
        command.extend(["--adopt-missing", "--write-runbooks"])
    command.append("--json")
    result = run_shell(" ".join(command), timeout=timeout)
    if int(result.get("exitCode", 1)) != 0:
        return {"ok": False, "stdout": result.get("stdout", ""), "stderr": result.get("stderr", "")}
    try:
        payload = json.loads(str(result.get("stdout", "") or "{}"))
        if isinstance(payload, dict):
            payload.setdefault("ok", True)
            return payload
    except json.JSONDecodeError:
        pass
    return {"ok": False, "error": "invalid governance output"}


def kickstart_label(label: str) -> None:
    subprocess.run(["launchctl", "kickstart", "-k", f"{GUI_DOMAIN}/{label}"], capture_output=True, text=True)
    subprocess.run(["launchctl", "kickstart", "-k", f"{USER_DOMAIN}/{label}"], capture_output=True, text=True)


def start_runtime_services() -> dict[str, object]:
    for label in (HEALTHD_LABEL, HELPER_LABEL, BRIDGE_LABEL, RELAY_SERVER_LABEL, RELAY_CONNECTOR_LABEL):
        kickstart_label(label)
    return {"exitCode": 0, "stdout": "runtime kickstarted", "stderr": ""}


class Handler(BaseHTTPRequestHandler):
    server_version = "DexRelayHealth/1.0"

    def _send_json(self, payload: dict[str, object], status: int = 200) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path: Path, content_type: str) -> None:
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/api/health":
            self._send_json(gather_status())
            return
        if parsed.path == "/api/projects":
            self._send_json({"projects": known_projects()})
            return
        if parsed.path == "/api/services":
            self._send_json(list_services())
            return
        if parsed.path == "/api/governance":
            self._send_json(governance_command("summary"))
            return
        if parsed.path == "/api/codex-fast":
            payload = codex_fast_command("report")
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/project-metrics":
            project_path = (query.get("path") or [""])[0]
            if not project_path.strip():
                self._send_json({"ok": False, "error": "path is required"}, 400)
                return
            payload = project_metrics(project_path)
            self._send_json(payload, 200 if bool(payload.get("ok")) else 404)
            return
        if parsed.path in ("/", "/index.html"):
            self._send_file(UI_DIR / "index.html", "text/html; charset=utf-8")
            return
        if parsed.path == "/app.js":
            self._send_file(UI_DIR / "app.js", "application/javascript; charset=utf-8")
            return
        if parsed.path == "/styles.css":
            self._send_file(UI_DIR / "styles.css", "text/css; charset=utf-8")
            return
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        body = parse_body(self)
        if parsed.path == "/api/actions/start-all":
            cwd = str(body.get("projectCWD") or DEFAULT_PROJECT)
            result = start_runtime_services()
            sync = run_shell(f"python3 {shlex.quote(str(SERVICECTL_SCRIPT))} sync-conf --json && python3 {shlex.quote(str(SERVICECTL_SCRIPT))} validate --json", cwd=PROJECT_ROOT, timeout=60)
            if int(sync.get("exitCode", 1)) != 0:
                result = sync
            self._send_json(action_response("start-all", result), 200 if int(result["exitCode"]) == 0 else 500)
            return
        if parsed.path == "/api/actions/restart-relay":
            result = start_runtime_services()
            self._send_json(action_response("restart-relay", result), 200 if int(result["exitCode"]) == 0 else 500)
            return
        if parsed.path == "/api/actions/open-xcode":
            result = run_shell("open -ga Xcode", timeout=20)
            self._send_json(action_response("open-xcode", result), 200 if int(result["exitCode"]) == 0 else 500)
            return
        if parsed.path == "/api/actions/install-service":
            result = start_runtime_services()
            self._send_json(action_response("install-service", result), 200 if int(result["exitCode"]) == 0 else 500)
            return
        if parsed.path == "/api/actions/sync-services":
            result = run_shell(
                f"python3 {shlex.quote(str(SERVICECTL_SCRIPT))} sync-conf --json && python3 {shlex.quote(str(SERVICECTL_SCRIPT))} validate --json",
                cwd=PROJECT_ROOT,
                timeout=60,
            )
            self._send_json(action_response("sync-services", result), 200 if int(result["exitCode"]) == 0 else 500)
            return
        if parsed.path == "/api/actions/scan-projects":
            payload = governance_command("reconcile", timeout=120)
            payload["status"] = gather_status()
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/reconcile-governance":
            payload = governance_command("reconcile", timeout=120)
            payload["status"] = gather_status()
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/update-unmanaged-governance":
            payload = governance_command("update-unmanaged", timeout=120)
            payload["status"] = gather_status()
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/update-all-governance":
            payload = governance_command("update-all", timeout=180)
            payload["status"] = gather_status()
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/update-project-governance":
            payload = governance_command("update-project", body=body, timeout=120)
            payload["status"] = gather_status()
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/codex-fast-report":
            payload = codex_fast_command("report")
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/codex-fast-backup":
            payload = codex_fast_command("backup")
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path == "/api/actions/codex-fast-apply":
            payload = codex_fast_command("apply", wait_for_codex_exit=bool(body.get("waitForCodexExit")))
            self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
            return
        if parsed.path.startswith("/api/services/"):
            parts = [part for part in parsed.path.split("/") if part]
            if len(parts) == 4 and parts[0] == "api" and parts[1] == "services" and parts[3] in {"start", "stop", "restart"}:
                payload = run_servicectl_action(parts[2], parts[3])
                payload["status"] = gather_status()
                self._send_json(payload, 200 if bool(payload.get("ok")) else 500)
                return
        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def log_message(self, fmt: str, *args: object) -> None:
        sys.stdout.write("[healthd] " + (fmt % args) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    UI_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"dexrelay health daemon listening on http://{HOST}:{PORT}")
    server.serve_forever()
