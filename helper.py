#!/usr/bin/env python3
import atexit
import hashlib
import json
import mimetypes
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import threading
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlencode, unquote, urlparse


DEFAULT_RUNTIME_ROOT = os.path.expanduser("~/Library/Application Support/DexRelay/runtime")
LEGACY_RUNTIME_ROOT = os.path.expanduser("~/src/CodexRelayBackendBootstrap")


def runtime_root_ready(path: str) -> bool:
    return any(
        os.path.isfile(os.path.join(path, relative))
        for relative in (
            "scripts/governancectl.py",
            "helper/helper.py",
            "bin/start-helper.sh",
        )
    )


def resolve_install_root() -> str:
    explicit = os.environ.get("CODEX_RELAY_ROOT")
    if explicit:
        return os.path.expanduser(explicit)
    if runtime_root_ready(DEFAULT_RUNTIME_ROOT):
        return DEFAULT_RUNTIME_ROOT
    if runtime_root_ready(LEGACY_RUNTIME_ROOT):
        return LEGACY_RUNTIME_ROOT
    return DEFAULT_RUNTIME_ROOT


INSTALL_ROOT = resolve_install_root()
SETUP_BASE_URL = os.environ.get("CODEX_RELAY_SETUP_BASE_URL", "https://assets.dexrelay.app").rstrip("/")
PROJECTS_ROOT = os.environ.get("CODEX_RELAY_PROJECTS_ROOT", os.path.expanduser("~/src"))
ADMIN_PROJECT_ROOT = os.environ.get("CODEX_RELAY_ADMIN_PROJECT_ROOT", os.path.join(PROJECTS_ROOT, "DexRelay Admin"))
BRIDGE_LABEL = os.environ.get("CODEX_RELAY_LABEL", "com.codexrelay.bootstrap")
BRIDGE_PORT = int(os.environ.get("CODEX_RELAY_BRIDGE_PORT", "4615"))
HELPER_LABEL = os.environ.get("CODEX_RELAY_HELPER_LABEL", "com.codexrelay.setuphelper")
HELPER_PORT = int(os.environ.get("CODEX_RELAY_HELPER_PORT", "4616"))
KEEP_AWAKE_LABEL = os.environ.get("CODEX_RELAY_KEEP_AWAKE_LABEL", "com.codexrelay.keepawake.bootstrap")
BONJOUR_SERVICE_TYPE = os.environ.get("CODEX_RELAY_BONJOUR_SERVICE_TYPE", "_dexrelay._tcp")
BONJOUR_SERVICE_DOMAIN = os.environ.get("CODEX_RELAY_BONJOUR_SERVICE_DOMAIN", "local.")
STATE_DIR = os.path.expanduser("~/Library/Application Support/CodexRelayHelper")
LOG_DIR = os.path.expanduser("~/Library/Logs/CodexRelayHelper")
STATE_FILE = os.path.join(STATE_DIR, "status.json")
SETUP_LOG = os.path.join(LOG_DIR, "setup.out.log")
SETUP_ERR_LOG = os.path.join(LOG_DIR, "setup.err.log")
OTA_PUBLIC_ROOT = os.environ.get("CODEX_RELAY_OTA_PUBLIC_ROOT", os.path.join(STATE_DIR, "ota", "public"))
HELPER_VERSION = "1.2.0"
PAIRING_TTL_SECONDS = int(os.environ.get("CODEX_RELAY_PAIRING_TTL_SECONDS", "600"))
RELAY_SERVER_PORT = int(os.environ.get("CODEX_RELAY_SERVER_PORT", "4620"))
RELAY_SERVER_PATH = os.environ.get("CODEX_RELAY_SERVER_PATH", "/relay").strip() or "/relay"

os.makedirs(STATE_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)
os.makedirs(OTA_PUBLIC_ROOT, exist_ok=True)

state_lock = threading.Lock()
setup_thread = None
pairings_lock = threading.Lock()
pairings = {}
bonjour_process_lock = threading.Lock()
bonjour_process = None
bonjour_registration = None


def spawn_installer(status_message: str, setup_state: str):
    update_state(
        setupRunning=True,
        setupState=setup_state,
        statusMessage=status_message,
        lastError=None,
    )

    with tempfile.NamedTemporaryFile(prefix="codexrelay-install-", suffix=".sh", delete=False) as handle:
        script_path = handle.name

    urllib.request.urlretrieve(f"{SETUP_BASE_URL}/install.sh", script_path)

    with open(SETUP_LOG, "a", encoding="utf-8") as stdout_handle, open(SETUP_ERR_LOG, "a", encoding="utf-8") as stderr_handle:
        subprocess.Popen(
            ["/bin/bash", script_path],
            env=install_command_environment(),
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
        )


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def utc_now():
    return datetime.now(timezone.utc)


def iso_after(seconds: int) -> str:
    return (utc_now() + timedelta(seconds=seconds)).isoformat()


def preferred_pairing_host(snapshot):
    for key in ("tailscaleDNSName", "tailscaleIP", "tailscaleHostName", "localNetworkIPv4", "localNetworkHostName"):
        value = snapshot.get(key)
        if isinstance(value, str):
            trimmed = value.strip().rstrip(".")
            if trimmed:
                return trimmed
    return None


def fallback_pairing_hosts(snapshot, primary_host: str):
    for key in ("tailscaleDNSName", "tailscaleIP", "tailscaleHostName"):
        value = snapshot.get(key)
        if isinstance(value, str):
            trimmed = value.strip().rstrip(".")
            if trimmed and trimmed != primary_host:
                yield trimmed


def build_pairing_uri(pairing_id: str, token: str, host: str, helper_port: int, bridge_port: int, expires_at: str, alt_hosts=None):
    query = urlencode({
        "id": pairing_id,
        "token": token,
        "host": host,
        "helperPort": helper_port,
        "bridgePort": bridge_port,
        "expiresAt": expires_at,
        "altHost": list(alt_hosts or []),
    }, doseq=True)
    return f"dexrelay-pair://claim?{query}"


def build_relay_url(host: str) -> str:
    path = RELAY_SERVER_PATH if RELAY_SERVER_PATH.startswith("/") else f"/{RELAY_SERVER_PATH}"
    return f"ws://{host}:{RELAY_SERVER_PORT}{path}"


def build_relay_bootstrap_uri(relay_url: str, pairing_id: str, device_id: str, display_name: str, token: str, expires_at: str):
    query = urlencode({
        "relay": relay_url,
        "pairingId": pairing_id,
        "deviceId": device_id,
        "displayName": display_name,
        "token": token,
        "expiresAt": expires_at,
    })
    return f"dexrelay-relay://bootstrap?{query}"


def prune_pairings_locked():
    now = utc_now()
    expired = []
    for pairing_id, payload in pairings.items():
        expires_at = payload.get("expiresAt")
        if not isinstance(expires_at, str):
            expired.append(pairing_id)
            continue
        try:
            if datetime.fromisoformat(expires_at.replace("Z", "+00:00")) <= now:
                expired.append(pairing_id)
        except Exception:
            expired.append(pairing_id)
    for pairing_id in expired:
        pairings.pop(pairing_id, None)


def create_pairing(device_name=None):
    snapshot = current_state()
    host = preferred_pairing_host(snapshot)
    if not host:
        raise RuntimeError("No reachable Mac host is currently available for pairing")

    pairing_id = secrets.token_urlsafe(12)
    token = secrets.token_urlsafe(24)
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    expires_at = iso_after(PAIRING_TTL_SECONDS)
    display_name = socket.gethostname()
    fallback_hosts = list(fallback_pairing_hosts(snapshot, host))

    payload = {
        "id": pairing_id,
        "tokenHash": token_hash,
        "host": host,
        "altHosts": fallback_hosts,
        "helperPort": HELPER_PORT,
        "bridgePort": BRIDGE_PORT,
        "createdAt": now_iso(),
        "expiresAt": expires_at,
        "claimedAt": None,
        "claimedBy": None,
        "displayName": display_name,
        "deviceName": (device_name or "").strip() or None,
    }

    with pairings_lock:
        prune_pairings_locked()
        pairings[pairing_id] = payload

    return {
        "pairingId": pairing_id,
        "pairingToken": token,
        "pairingURI": build_pairing_uri(pairing_id, token, host, HELPER_PORT, BRIDGE_PORT, expires_at, fallback_hosts),
        "helperPort": HELPER_PORT,
        "bridgePort": BRIDGE_PORT,
        "preferredHost": host,
        "displayName": display_name,
        "expiresAt": expires_at,
    }


def claim_pairing(pairing_id: str, token: str, device_name=None):
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    with pairings_lock:
        prune_pairings_locked()
        payload = pairings.get(pairing_id)
        if payload is None:
            raise KeyError("Pairing code was not found or has expired")
        if payload.get("claimedAt"):
            raise PermissionError("Pairing code has already been used")
        if payload.get("tokenHash") != token_hash:
            raise PermissionError("Pairing token is invalid")
        payload["claimedAt"] = now_iso()
        payload["claimedBy"] = (device_name or "").strip() or "iPhone"
        host = payload.get("host")

    snapshot = current_state()
    snapshot["preferredHost"] = preferred_pairing_host(snapshot) or host
    snapshot["pairingClaimed"] = True
    snapshot["pairingClaimedAt"] = now_iso()
    snapshot["pairingClaimedBy"] = (device_name or "").strip() or "iPhone"
    return snapshot


def create_relay_bootstrap(device_name=None):
    snapshot = current_state()
    host = preferred_pairing_host(snapshot)
    if not host:
        raise RuntimeError("No reachable Mac host is currently available for relay bootstrap")

    pairing_id = secrets.token_urlsafe(12)
    token = secrets.token_urlsafe(24)
    expires_at = iso_after(PAIRING_TTL_SECONDS)
    relay_url = build_relay_url(host)
    phone_device_id = f"iphone-{secrets.token_hex(6)}"
    display_name = (device_name or "").strip() or "DexRelay iPhone"
    mac_display_name = socket.gethostname()

    return {
        "pairingId": pairing_id,
        "bootstrapToken": token,
        "relayWebSocketURL": relay_url,
        "relayBootstrapURI": build_relay_bootstrap_uri(
            relay_url,
            pairing_id,
            phone_device_id,
            display_name,
            token,
            expires_at,
        ),
        "phoneDeviceID": phone_device_id,
        "phoneDisplayName": display_name,
        "macDisplayName": mac_display_name,
        "relayServerPort": RELAY_SERVER_PORT,
        "relayServerPath": RELAY_SERVER_PATH,
        "preferredHost": host,
        "expiresAt": expires_at,
    }


state = {
    "helperVersion": HELPER_VERSION,
    "helperLabel": HELPER_LABEL,
    "helperPort": HELPER_PORT,
    "setupRunning": False,
    "setupState": "idle",
    "statusMessage": "Setup helper is idle",
    "bridgeReachable": False,
    "bridgePort": BRIDGE_PORT,
    "installRoot": INSTALL_ROOT,
    "defaultInstallRoot": DEFAULT_RUNTIME_ROOT,
    "legacyInstallRoot": LEGACY_RUNTIME_ROOT,
    "otaPublicRoot": OTA_PUBLIC_ROOT,
    "projectsRoot": PROJECTS_ROOT,
    "adminProjectRoot": ADMIN_PROJECT_ROOT,
    "tailscaleInstalled": False,
    "tailscaleConnected": False,
    "tailscaleCLIPath": None,
    "tailscaleIP": None,
    "tailscaleDNSName": None,
    "tailscaleHostName": None,
    "localNetworkIPv4": None,
    "localNetworkHostName": None,
    "bonjourAdvertised": False,
    "bonjourServiceName": None,
    "bonjourServiceType": BONJOUR_SERVICE_TYPE,
    "keepAwakeEnabled": False,
    "keepAwakeLabel": KEEP_AWAKE_LABEL,
    "lastError": None,
    "lastUpdated": now_iso(),
}


def resolve_tailscale_cli():
    tailscale_from_path = shutil.which("tailscale")
    if tailscale_from_path:
        return [tailscale_from_path]
    for base in tailscale_cli_candidates():
        candidate = base[0]
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return base
    return None


def tailscale_cli_candidates():
    return [
        ["/opt/homebrew/bin/tailscale"],
        ["/usr/local/bin/tailscale"],
    ]


def detect_tailscale_identity():
    cli = resolve_tailscale_cli()
    if cli is not None:
        try:
            output = subprocess.check_output(
                cli + ["status", "--json"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            payload = json.loads(output)
            self_payload = payload.get("Self") or {}
            dns_name = (self_payload.get("DNSName") or "").rstrip(".")
            ips = self_payload.get("TailscaleIPs") or []
            ipv4 = next((item for item in ips if isinstance(item, str) and item.startswith("100.")), None)
            return {
                "tailscaleInstalled": True,
                "tailscaleConnected": True,
                "tailscaleCLIPath": cli[0],
                "tailscaleIP": ipv4,
                "tailscaleDNSName": dns_name or None,
                "tailscaleHostName": self_payload.get("HostName"),
            }
        except Exception:
            pass

    if cli is not None:
        try:
            output = subprocess.check_output(
                cli + ["ip", "-4"],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
            for line in output.splitlines():
                line = line.strip()
                if line.startswith("100."):
                    return {
                        "tailscaleInstalled": True,
                        "tailscaleConnected": True,
                        "tailscaleCLIPath": cli[0],
                        "tailscaleIP": line,
                        "tailscaleDNSName": None,
                        "tailscaleHostName": None,
                    }
        except Exception:
            return {
                "tailscaleInstalled": True,
                "tailscaleConnected": False,
                "tailscaleCLIPath": cli[0],
                "tailscaleIP": None,
                "tailscaleDNSName": None,
                "tailscaleHostName": None,
            }

    try:
        output = subprocess.check_output(
            ["/sbin/ifconfig"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        for line in output.splitlines():
            stripped = line.strip()
            if stripped.startswith("inet 100."):
                parts = stripped.split()
                if len(parts) >= 2:
                    return {
                        "tailscaleInstalled": False,
                        "tailscaleConnected": True,
                        "tailscaleCLIPath": None,
                        "tailscaleIP": parts[1],
                        "tailscaleDNSName": None,
                        "tailscaleHostName": None,
                    }
    except Exception:
        pass

    return {
        "tailscaleInstalled": cli is not None,
        "tailscaleConnected": False,
        "tailscaleCLIPath": cli[0] if cli is not None else None,
        "tailscaleIP": None,
        "tailscaleDNSName": None,
        "tailscaleHostName": None,
    }


def detect_local_network_identity():
    ipv4 = None
    try:
        output = subprocess.check_output(
            ["/sbin/ifconfig"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        for line in output.splitlines():
            stripped = line.strip()
            if not stripped.startswith("inet "):
                continue
            parts = stripped.split()
            if len(parts) < 2:
                continue
            candidate = parts[1]
            if candidate.startswith("127.") or candidate.startswith("169.254.") or candidate.startswith("100."):
                continue
            ipv4 = candidate
            break
    except Exception:
        pass

    local_host_base = None
    computer_name = None
    try:
        local_host_base = subprocess.check_output(
            ["scutil", "--get", "LocalHostName"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip().rstrip(".")
    except Exception:
        pass

    try:
        computer_name = subprocess.check_output(
            ["scutil", "--get", "ComputerName"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        pass

    if not local_host_base:
        fallback_host = (socket.gethostname() or "").strip().rstrip(".")
        if fallback_host.lower().endswith(".local"):
            local_host_base = fallback_host[:-6]
        else:
            local_host_base = fallback_host or None

    local_host_name = f"{local_host_base}.local" if local_host_base else None

    return {
        "localNetworkIPv4": ipv4,
        "localNetworkHostName": local_host_name,
        "localNetworkServiceName": local_host_base,
        "localNetworkComputerName": computer_name,
    }


def resolve_dns_sd_binary():
    candidate = shutil.which("dns-sd") or "/usr/bin/dns-sd"
    if os.path.exists(candidate) and os.access(candidate, os.X_OK):
        return candidate
    return None


def preferred_bonjour_service_name(snapshot):
    computer_name = (snapshot.get("localNetworkComputerName") or "").strip().rstrip(".")
    if computer_name:
        return computer_name
    local_host = (snapshot.get("localNetworkServiceName") or "").strip().rstrip(".")
    if local_host:
        return local_host
    return (socket.gethostname() or "DexRelay Mac").strip().rstrip(".") or "DexRelay Mac"


def bonjour_txt_records(snapshot):
    records = [
        f"helper={HELPER_PORT}",
        f"bridge={BRIDGE_PORT}",
        f"version={HELPER_VERSION}",
    ]
    local_host = (snapshot.get("localNetworkHostName") or "").strip().rstrip(".")
    if local_host:
        records.append(f"host={local_host}")
    return records


def stop_bonjour_advertisement():
    global bonjour_process, bonjour_registration
    with bonjour_process_lock:
        process = bonjour_process
        bonjour_process = None
        bonjour_registration = None
    if process is None:
        return
    try:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=2)
    except Exception:
        try:
            process.kill()
        except Exception:
            pass


def ensure_bonjour_advertisement(snapshot):
    global bonjour_process, bonjour_registration
    dns_sd = resolve_dns_sd_binary()
    service_name = preferred_bonjour_service_name(snapshot)
    desired = (service_name, BONJOUR_SERVICE_TYPE, HELPER_PORT)

    with bonjour_process_lock:
        if bonjour_process is not None and bonjour_process.poll() is None and bonjour_registration == desired:
            return True, service_name

    stop_bonjour_advertisement()

    if dns_sd is None or not service_name:
        return False, service_name

    try:
        process = subprocess.Popen(
            [
                dns_sd,
                "-R",
                service_name,
                BONJOUR_SERVICE_TYPE,
                BONJOUR_SERVICE_DOMAIN,
                str(HELPER_PORT),
                *bonjour_txt_records(snapshot),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return False, service_name

    with bonjour_process_lock:
        bonjour_process = process
        bonjour_registration = desired
    return True, service_name


def bridge_reachable() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.4)
        return sock.connect_ex(("127.0.0.1", BRIDGE_PORT)) == 0


def launch_agent_loaded(label: str) -> bool:
    uid = str(os.getuid())
    for domain in (f"gui/{uid}", f"user/{uid}"):
        try:
            subprocess.check_output(
                ["launchctl", "print", f"{domain}/{label}"],
                stderr=subprocess.DEVNULL,
                text=True,
            )
            return True
        except Exception:
            continue
    return False


def persist_state():
    snapshot = current_state()
    with open(STATE_FILE, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, indent=2, sort_keys=True)


def update_state(**changes):
    with state_lock:
        state.update(changes)
        state["lastUpdated"] = now_iso()
    persist_state()


def current_state():
    with state_lock:
        snapshot = dict(state)
    snapshot["bridgeReachable"] = bridge_reachable()
    snapshot.update(detect_local_network_identity())
    snapshot.update(detect_tailscale_identity())
    advertised, service_name = ensure_bonjour_advertisement(snapshot)
    snapshot["bonjourAdvertised"] = advertised
    snapshot["bonjourServiceName"] = service_name or None
    snapshot["bonjourServiceType"] = BONJOUR_SERVICE_TYPE
    snapshot["keepAwakeEnabled"] = launch_agent_loaded(KEEP_AWAKE_LABEL)
    if snapshot["bridgeReachable"] and not snapshot["setupRunning"]:
        snapshot["setupState"] = "completed"
        snapshot["statusMessage"] = "Bootstrap install finished"
        snapshot["lastError"] = None
    snapshot["otaPublicRoot"] = OTA_PUBLIC_ROOT
    return snapshot


def resolve_ota_file(request_path: str):
    parsed = urlparse(request_path)
    raw_path = unquote(parsed.path or "")
    relative = raw_path.lstrip("/")
    if not relative or relative.startswith("api/") or relative == "health":
        return None

    root = Path(OTA_PUBLIC_ROOT).resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None

    if candidate.is_dir():
        candidate = candidate / "index.html"
    if not candidate.exists() or not candidate.is_file():
        return None
    return candidate


def ota_content_type(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".plist":
        return "text/xml; charset=utf-8"
    if suffix == ".ipa":
        return "application/octet-stream"
    if suffix == ".json":
        return "application/json; charset=utf-8"
    guessed = mimetypes.guess_type(path.name)[0]
    return guessed or "application/octet-stream"


def install_command_environment():
    env = os.environ.copy()
    env["CODEX_RELAY_ROOT"] = INSTALL_ROOT
    env["CODEX_RELAY_SETUP_BASE_URL"] = SETUP_BASE_URL
    env["CODEX_RELAY_PROJECTS_ROOT"] = PROJECTS_ROOT
    env["CODEX_RELAY_ADMIN_PROJECT_ROOT"] = ADMIN_PROJECT_ROOT
    env["CODEX_RELAY_LABEL"] = BRIDGE_LABEL
    env["CODEX_RELAY_BRIDGE_PORT"] = str(BRIDGE_PORT)
    env["CODEX_RELAY_HELPER_LABEL"] = HELPER_LABEL
    env["CODEX_RELAY_HELPER_PORT"] = str(HELPER_PORT)
    env["CODEX_RELAY_SERVER_PORT"] = str(RELAY_SERVER_PORT)
    env["CODEX_RELAY_SERVER_PATH"] = RELAY_SERVER_PATH
    return env


def request_keep_awake(enabled: bool):
    update_state(
        setupRunning=True,
        setupState="repairing",
        statusMessage="Enabling Mac keep-awake" if enabled else "Disabling Mac keep-awake",
        lastError=None,
    )

    with tempfile.NamedTemporaryFile(prefix="codexrelay-install-", suffix=".sh", delete=False) as handle:
        script_path = handle.name

    urllib.request.urlretrieve(f"{SETUP_BASE_URL}/install.sh", script_path)
    env = install_command_environment()
    env["CODEX_RELAY_KEEP_AWAKE"] = "1" if enabled else "0"

    with open(SETUP_LOG, "a", encoding="utf-8") as stdout_handle, open(SETUP_ERR_LOG, "a", encoding="utf-8") as stderr_handle:
        subprocess.Popen(
            ["/bin/bash", script_path],
            env=env,
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
        )


def request_tailscale_reconnect():
    update_state(
        setupRunning=True,
        setupState="repairing",
        statusMessage="Reconnecting Tailscale on the Mac",
        lastError=None,
    )

    cli = resolve_tailscale_cli()
    if cli is None:
        update_state(
            setupRunning=False,
            setupState="failed",
            statusMessage="Tailscale is not installed on this Mac",
            lastError="tailscale CLI not found",
        )
        return

    try:
        subprocess.run(
            ["/usr/bin/open", "-g", "-a", "Tailscale"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
    except Exception:
        pass

    try:
        subprocess.run(
            cli + ["up"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=20,
        )
    except Exception:
        pass

    snapshot = current_state()
    if snapshot.get("tailscaleConnected"):
        update_state(
            setupRunning=False,
            setupState="completed",
            statusMessage="Tailscale is connected on the Mac",
            lastError=None,
        )
    else:
        update_state(
            setupRunning=False,
            setupState="failed",
            statusMessage="Could not reconnect Tailscale automatically",
            lastError="Open Tailscale on the Mac and confirm it is connected",
        )


def run_setup():
    try:
        spawn_installer(
            status_message="Running bootstrap installer on the Mac",
            setup_state="installing",
        )
    except Exception as error:
        update_state(
            setupRunning=False,
            setupState="failed",
            statusMessage="Bootstrap install failed",
            lastError=str(error),
        )


def run_repair():
    try:
        spawn_installer(
            status_message="Repairing DexRelay on the Mac",
            setup_state="repairing",
        )
    except Exception as error:
        update_state(
            setupRunning=False,
            setupState="failed",
            statusMessage="DexRelay repair failed",
            lastError=str(error),
        )


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status_code: int, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_ota_file(self, file_path: Path, include_body: bool):
        body = b""
        if include_body:
            with file_path.open("rb") as handle:
                body = handle.read()
        content_length = file_path.stat().st_size if not include_body else len(body)
        self.send_response(200)
        self.send_header("Content-Type", ota_content_type(file_path))
        self.send_header("Content-Length", str(content_length))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"ok": True, "service": "codex-relay-setup-helper"})
            return

        if self.path == "/api/helper/status":
            self._send_json(200, current_state())
            return

        file_path = resolve_ota_file(self.path)
        if file_path is not None:
            self._send_ota_file(file_path, include_body=True)
            return

        self._send_json(404, {"error": "Not found"})

    def do_HEAD(self):
        file_path = resolve_ota_file(self.path)
        if file_path is not None:
            self._send_ota_file(file_path, include_body=False)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        global setup_thread

        if self.path not in {
            "/api/helper/setup",
            "/api/helper/repair",
            "/api/helper/wake",
            "/api/helper/tailscale",
            "/api/helper/pairing/request",
            "/api/helper/pairing/claim",
            "/api/helper/relay-bootstrap/request",
        }:
            self._send_json(404, {"error": "Not found"})
            return

        content_length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            payload = json.loads(body.decode("utf-8") or "{}")
        except Exception:
            payload = {}

        if self.path == "/api/helper/pairing/request":
            try:
                self._send_json(200, create_pairing(device_name=payload.get("deviceName")))
            except Exception as error:
                self._send_json(503, {"error": str(error)})
            return

        if self.path == "/api/helper/pairing/claim":
            pairing_id = str(payload.get("pairingId") or "").strip()
            token = str(payload.get("pairingToken") or "").strip()
            if not pairing_id or not token:
                self._send_json(400, {"error": "pairingId and pairingToken are required"})
                return
            try:
                self._send_json(200, claim_pairing(pairing_id, token, device_name=payload.get("deviceName")))
            except KeyError as error:
                self._send_json(404, {"error": str(error)})
            except PermissionError as error:
                self._send_json(409, {"error": str(error)})
            except Exception as error:
                self._send_json(500, {"error": str(error)})
            return

        if self.path == "/api/helper/relay-bootstrap/request":
            try:
                self._send_json(200, create_relay_bootstrap(device_name=payload.get("deviceName")))
            except Exception as error:
                self._send_json(503, {"error": str(error)})
            return

        with state_lock:
            already_running = state["setupRunning"]

        if already_running:
            self._send_json(202, current_state())
            return

        if self.path == "/api/helper/wake":
            enabled = bool(payload.get("enabled", True))
            target = lambda: request_keep_awake(enabled)
        elif self.path == "/api/helper/tailscale":
            target = request_tailscale_reconnect
        else:
            target = run_repair if self.path == "/api/helper/repair" else run_setup
        setup_thread = threading.Thread(target=target, daemon=True)
        setup_thread.start()
        self._send_json(202, current_state())

    def log_message(self, fmt, *args):
        line = "[helper] " + (fmt % args) + "\n"
        with open(os.path.join(LOG_DIR, "helper-http.log"), "a", encoding="utf-8") as handle:
            handle.write(line)


def main():
    atexit.register(stop_bonjour_advertisement)
    persist_state()
    server = ThreadingHTTPServer(("0.0.0.0", HELPER_PORT), Handler)
    print(f"codex relay setup helper listening on http://0.0.0.0:{HELPER_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
