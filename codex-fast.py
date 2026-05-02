#!/usr/bin/env python3
"""Backup-first Codex local-state maintenance.

Default mode is a read-only, privacy-safe report. Use --apply to archive/move/normalize.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path


THREAD_ID_RE = re.compile(
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})",
    re.I,
)
PROJECT_HEADER_RE = re.compile(r"^\[projects\.([\"'])(.+)\1\]\s*$")
TEMP_PROJECT_RE = re.compile(
    r"(\\AppData\\Local\\Temp\\|/AppData/Local/Temp/|\\Temp\\codex-|/Temp/codex-|\\Temp\\spark-|/Temp/spark-)",
    re.I,
)


@dataclass
class SessionCandidate:
    size: int
    thread_id: str
    title: str
    source: Path
    relative: Path
    updated_at: int | None


@dataclass
class TempBuildCandidate:
    path: Path
    size: int
    modified_at: float
    reason: str


@dataclass
class ClaudeSessionCandidate:
    session_id: str
    title: str
    project: str
    path: Path
    size: int
    updated_at: float
    message_count: int


def now_stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def codex_home_from_args(value: str | None) -> Path:
    if value:
        return Path(value).expanduser().resolve()
    override = os.environ.get("CODEX_HOME")
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / ".codex"


def documents_backup_root() -> Path:
    docs = Path.home() / "Documents" / "Codex" / "codex-backups"
    if docs.parent.exists() or platform.system() == "Windows":
        return docs
    return Path.home() / ".codex" / "backups"


def size_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_file():
        return path.stat().st_size
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            try:
                total += item.stat().st_size
            except OSError:
                pass
    return total


def gb(value: int) -> str:
    return f"{value / 1024 / 1024 / 1024:.3f}"


def mb(value: int) -> str:
    return f"{value / 1024 / 1024:.1f}"


def report(line: str) -> None:
    print(line)


def sqlite_connect(path: Path, *, readonly: bool) -> sqlite3.Connection:
    if readonly:
        return sqlite3.connect(f"{canonical_path(path).as_uri()}?mode=ro", uri=True)
    return sqlite3.connect(path)


def canonical_path(path: Path) -> Path:
    try:
        return path.resolve(strict=False)
    except OSError:
        return path.absolute()


def codex_processes_running() -> list[str]:
    system = platform.system()
    try:
        if system == "Windows":
            output = subprocess.check_output(
                ["powershell", "-NoProfile", "-Command", "Get-CimInstance Win32_Process | Select-Object Name,ProcessId,CommandLine | ConvertTo-Json -Compress"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
            if not output.strip():
                return []
            data = json.loads(output)
            rows = data if isinstance(data, list) else [data]
            hits = []
            for row in rows:
                name = str(row.get("Name") or "")
                cmd = str(row.get("CommandLine") or "")
                pid = row.get("ProcessId")
                if name == "Codex.exe" or (name == "codex.exe" and ("app-server" in cmd or "OpenAI.Codex" in cmd)):
                    hits.append(f"{pid} {name}")
            return hits
        output = subprocess.check_output(["ps", "-axo", "pid=,comm=,args="], text=True)
        hits = []
        for line in output.splitlines():
            lower = line.lower()
            if "codex" in lower and ("app-server" in lower or "openai.codex" in lower or "codex desktop" in lower):
                hits.append(line.strip())
        return hits
    except Exception:
        return []


def wait_for_codex_exit() -> None:
    while codex_processes_running():
        time.sleep(2)


def sqlite_backup(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    source = sqlite_connect(src, readonly=True)
    target = sqlite3.connect(dst)
    source.backup(target)
    target.close()
    source.close()


def copy_if_exists(src: Path, dst: Path) -> None:
    if not src.exists():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(
            src,
            dst,
            ignore=shutil.ignore_patterns(
                "node_modules",
                ".git",
                ".next",
                "dist",
                "build",
                ".venv",
                "__pycache__",
                ".pytest_cache",
            ),
            dirs_exist_ok=True,
        )
    else:
        shutil.copy2(src, dst)
    report(f"backed_up {src.name}")


def backup_metadata(codex_home: Path, backup_root: Path) -> None:
    backup_root.mkdir(parents=True, exist_ok=True)
    for name in [
        ".codex-global-state.json",
        "config.toml",
        "history.jsonl",
        "installation_id",
        "models_cache.json",
        "session_index.jsonl",
        "version.json",
        "memories",
        "skills",
        "rules",
        "plugins",
        "automations",
    ]:
        copy_if_exists(codex_home / name, backup_root / name)
    sqlite_backup(codex_home / "state_5.sqlite", backup_root / "state_5.sqlite")


def load_pinned(codex_home: Path) -> set[str]:
    path = codex_home / ".codex-global-state.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return set(data.get("pinned-thread-ids", []))
    except Exception:
        return set()


def normalize_extended_path(value: str) -> str:
    if value.startswith("\\\\?\\UNC\\"):
        return "\\\\" + value[8:]
    if value.startswith("\\\\?\\"):
        return value[4:]
    return value


def normalize_sqlite_paths(conn: sqlite3.Connection, apply: bool) -> int:
    cur = conn.cursor()
    total = 0
    tables = [
        row[0]
        for row in cur.execute(
            "select name from sqlite_master where type='table' and name not like 'sqlite_%'"
        )
    ]
    for table in tables:
        cols = cur.execute(f'pragma table_info("{table}")').fetchall()
        text_cols = [col[1] for col in cols if "TEXT" in (col[2] or "").upper() or col[2] == ""]
        for col in text_cols:
            rows = cur.execute(
                f'select rowid, "{col}" from "{table}" where "{col}" like ?',
                ("\\\\?\\%",),
            ).fetchall()
            changed = 0
            for rowid, value in rows:
                if isinstance(value, str) and value.startswith("\\\\?\\"):
                    changed += 1
                    if apply:
                        cur.execute(
                            f'update "{table}" set "{col}"=? where rowid=?',
                            (normalize_extended_path(value), rowid),
                        )
            if changed:
                report(f"extended_paths {table}.{col} {changed}")
                total += changed
    if total == 0:
        report("extended_paths 0")
    return total


def active_session_candidates(
    conn: sqlite3.Connection,
    codex_home: Path,
    archive_older_than_days: int,
) -> list[SessionCandidate]:
    sessions_root = codex_home / "sessions"
    sessions_root_canonical = canonical_path(sessions_root)
    cutoff = int((datetime.now() - timedelta(days=archive_older_than_days)).timestamp())
    pinned = load_pinned(codex_home)
    rows = conn.execute(
        "select id, title, rollout_path, updated_at from threads where archived_at is null"
    ).fetchall()
    candidates: list[SessionCandidate] = []
    for thread_id, title, rollout_path, updated_at in rows:
        if thread_id in pinned or not rollout_path:
            continue
        if updated_at is not None and int(updated_at) >= cutoff:
            continue
        source = Path(rollout_path)
        if not source.exists():
            continue
        try:
            relative = canonical_path(source).relative_to(sessions_root_canonical)
        except ValueError:
            continue
        candidates.append(
            SessionCandidate(source.stat().st_size, thread_id, title or "", source, relative, updated_at)
        )
    candidates.sort(key=lambda item: item.size, reverse=True)
    return candidates


def archive_sessions(
    conn: sqlite3.Connection,
    candidates: list[SessionCandidate],
    codex_home: Path,
    backup_root: Path,
    stamp: str,
    apply: bool,
    details: bool,
) -> None:
    total = sum(item.size for item in candidates)
    report(f"old_session_candidates {len(candidates)}")
    report(f"old_session_candidate_gb {gb(total)}")
    for index, item in enumerate(candidates[:10], start=1):
        label = f"session_{index:03d}"
        if details:
            report(f"large_session_mb {mb(item.size)} {label} thread_id={item.thread_id} title={item.title[:70]}")
        else:
            report(f"large_session_mb {mb(item.size)} {label}")
    if not apply or not candidates:
        return

    archive_root = codex_home / "archived_sessions" / f"keep-codex-fast-{stamp}"
    manifest = backup_root / "moved-sessions.jsonl"
    archive_root.mkdir(parents=True, exist_ok=True)
    now = int(time.time())
    cur = conn.cursor()
    with manifest.open("w", encoding="utf-8") as handle:
        for item in candidates:
            dest = archive_root / item.relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(item.source), str(dest))
            record = {
                "thread_id": item.thread_id,
                "bytes": item.size,
                "from": str(item.source),
                "to": str(dest),
            }
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
            cur.execute(
                "update threads set rollout_path=?, archived=1, archived_at=? where id=?",
                (str(dest), now, item.thread_id),
            )
    write_session_restore_script(manifest, codex_home / "state_5.sqlite", backup_root)
    report(f"archived_sessions_root {archive_root}")
    report(f"archived_sessions_manifest {manifest}")


def write_session_restore_script(manifest: Path, state_db: Path, backup_root: Path) -> None:
    restore = backup_root / "restore-sessions.py"
    restore.write_text(
        f'''import json
import shutil
import sqlite3
from pathlib import Path

manifest = Path(r"{manifest}")
db = Path(r"{state_db}")
conn = sqlite3.connect(db)
conn.execute("pragma busy_timeout=10000")
for line in manifest.read_text(encoding="utf-8").splitlines():
    rec = json.loads(line)
    src = Path(rec["to"])
    dest = Path(rec["from"])
    if src.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dest))
    if rec.get("thread_id"):
        conn.execute(
            "update threads set rollout_path=?, archived=0, archived_at=NULL where id=?",
            (str(dest), rec["thread_id"]),
        )
conn.commit()
conn.close()
''',
        encoding="utf-8",
    )
    report(f"session_restore_script {restore}")


def prune_config(codex_home: Path, backup_root: Path, apply: bool, write_artifacts: bool) -> None:
    path = codex_home / "config.toml"
    if not path.exists():
        report("config_prune_candidates 0")
        return
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    out: list[str] = []
    removed: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        match = PROJECT_HEADER_RE.match(line)
        if not match:
            out.append(line)
            i += 1
            continue
        project_path = match.group(2)
        block = [line]
        i += 1
        while i < len(lines) and not lines[i].startswith("["):
            block.append(lines[i])
            i += 1
        should_remove = bool(TEMP_PROJECT_RE.search(project_path)) or not Path(project_path).exists()
        if should_remove:
            removed.append(project_path)
        else:
            out.extend(block)

    if write_artifacts:
        (backup_root / "pruned-projects.txt").write_text(
            "\n".join(removed) + ("\n" if removed else ""),
            encoding="utf-8",
        )
    report(f"config_prune_candidates {len(removed)}")
    if apply and removed:
        path.write_text("\n".join(out) + "\n", encoding="utf-8")
        report("config_pruned applied")


def move_stale_worktrees(codex_home: Path, backup_root: Path, days: int, stamp: str, apply: bool) -> None:
    root = codex_home / "worktrees"
    if not root.exists():
        report("worktree_candidates 0")
        return
    cutoff = time.time() - days * 24 * 60 * 60
    candidates = [path for path in root.iterdir() if path.is_dir() and path.stat().st_mtime < cutoff]
    total = sum(size_bytes(path) for path in candidates)
    report(f"worktree_candidates {len(candidates)}")
    report(f"worktree_candidate_gb {gb(total)}")
    if not apply or not candidates:
        return
    archive_root = codex_home / "archived_worktrees" / f"keep-codex-fast-{stamp}"
    manifest = backup_root / "moved-worktrees.jsonl"
    archive_root.mkdir(parents=True, exist_ok=True)
    with manifest.open("w", encoding="utf-8") as handle:
        for source in candidates:
            dest = archive_root / source.name
            item_size = size_bytes(source)
            shutil.move(str(source), str(dest))
            handle.write(json.dumps({"from": str(source), "to": str(dest), "bytes": item_size}) + "\n")
    report(f"worktree_archive_root {archive_root}")
    report(f"worktree_manifest {manifest}")


def temp_roots() -> list[Path]:
    roots = [Path(tempfile.gettempdir()), Path("/tmp")]
    env_tmp = os.environ.get("TMPDIR")
    if env_tmp:
        roots.append(Path(env_tmp))
    seen: set[str] = set()
    unique: list[Path] = []
    for root in roots:
        try:
            canonical = str(canonical_path(root))
        except OSError:
            canonical = str(root)
        if canonical not in seen and root.exists():
            seen.add(canonical)
            unique.append(root)
    return unique


def temp_build_reason(path: Path) -> str | None:
    name = path.name
    exact_names = {
        "codex-ota": "DexRelay OTA package output",
        "codex-ota-derived-data": "DexRelay OTA DerivedData",
        "codexrelay-simulator-smoke": "DexRelay simulator smoke-test project",
        "codexremote-tests": "CodexRemote test DerivedData",
        "CodexPerfRegression": "DexRelay performance-test DerivedData",
    }
    if name in exact_names:
        return exact_names[name]
    prefix_reasons = [
        ("CodexDeviceBuild.", "DexRelay iPhone run DerivedData"),
        ("dexrelay-xcode-run-", "DexRelay app Run-on-iPhone DerivedData"),
        ("CodexRemote-codex-", "DexRelay/CodexRemote verification DerivedData"),
        ("CodexRemoteCLI", "CodexRemote CLI DerivedData"),
        ("dexrelay-appstore-screenshots", "DexRelay App Store screenshot output"),
    ]
    for prefix, reason in prefix_reasons:
        if name.startswith(prefix):
            return reason
    return None


def stale_temp_build_candidates(older_than_hours: int) -> list[TempBuildCandidate]:
    cutoff = time.time() - older_than_hours * 60 * 60
    candidates: list[TempBuildCandidate] = []
    seen: set[str] = set()
    for root in temp_roots():
        try:
            children = list(root.iterdir())
        except OSError:
            continue
        for path in children:
            reason = temp_build_reason(path)
            if reason is None:
                continue
            try:
                stat = path.stat()
            except OSError:
                continue
            if stat.st_mtime >= cutoff:
                continue
            canonical = str(canonical_path(path))
            if canonical in seen:
                continue
            seen.add(canonical)
            candidates.append(
                TempBuildCandidate(
                    path=path,
                    size=size_bytes(path),
                    modified_at=stat.st_mtime,
                    reason=reason,
                )
            )
    candidates.sort(key=lambda item: item.size, reverse=True)
    return candidates


def clean_stale_temp_builds(backup_root: Path, older_than_hours: int, apply: bool, details: bool) -> None:
    candidates = stale_temp_build_candidates(older_than_hours)
    total = sum(item.size for item in candidates)
    report(f"xcode_tmp_candidates {len(candidates)}")
    report(f"xcode_tmp_candidate_gb {gb(total)}")
    for index, item in enumerate(candidates[:10], start=1):
        label = f"xcode_tmp_{index:03d}"
        if details:
            age_hours = max(0.0, (time.time() - item.modified_at) / 3600)
            report(f"xcode_tmp_mb {mb(item.size)} {label} age_hours={age_hours:.1f} reason={item.reason} path={item.path}")
        else:
            report(f"xcode_tmp_mb {mb(item.size)} {label}")
    if not apply or not candidates:
        return

    manifest = backup_root / "removed-xcode-temp-builds.jsonl"
    manifest.parent.mkdir(parents=True, exist_ok=True)
    removed = 0
    with manifest.open("w", encoding="utf-8") as handle:
        for item in candidates:
            record = {
                "path": str(item.path),
                "bytes": item.size,
                "modified_at": int(item.modified_at),
                "reason": item.reason,
            }
            try:
                if item.path.is_dir():
                    shutil.rmtree(item.path)
                else:
                    item.path.unlink()
                record["removed"] = True
                removed += 1
            except OSError as exc:
                record["removed"] = False
                record["error"] = str(exc)
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    report(f"xcode_tmp_removed {removed}")
    report(f"xcode_tmp_manifest {manifest}")


def claude_home_from_args(value: str | None) -> Path:
    if value:
        return Path(value).expanduser().resolve()
    override = os.environ.get("CLAUDE_CONFIG_DIR") or os.environ.get("CLAUDE_HOME")
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / ".claude"


def claude_text_from_record(record: dict[str, object]) -> str:
    message = record.get("message")
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return " ".join(content.split())
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                parts.append(str(item["text"]))
        return " ".join(" ".join(parts).split())
    return ""


def summarize_claude_session(path: Path) -> ClaudeSessionCandidate | None:
    try:
        stat = path.stat()
    except OSError:
        return None
    session_id = path.stem
    first_user = ""
    last_user = ""
    last_assistant = ""
    message_count = 0
    updated_at = stat.st_mtime
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        raw = ""
    if len(raw) > 1024 * 1024:
        raw = raw[-1024 * 1024 :]
        first_newline = raw.find("\n")
        if first_newline >= 0:
            raw = raw[first_newline + 1 :]
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        if isinstance(record.get("sessionId"), str) and str(record["sessionId"]).strip():
            session_id = str(record["sessionId"]).strip()
        if isinstance(record.get("timestamp"), str):
            try:
                updated_at = max(updated_at, datetime.fromisoformat(str(record["timestamp"]).replace("Z", "+00:00")).timestamp())
            except ValueError:
                pass
        role = ""
        message = record.get("message")
        if isinstance(message, dict) and isinstance(message.get("role"), str):
            role = str(message["role"])
        elif isinstance(record.get("type"), str):
            role = str(record["type"])
        text = claude_text_from_record(record)
        if not text:
            continue
        message_count += 1
        if role == "user":
            first_user = first_user or text
            last_user = text
        elif role == "assistant":
            last_assistant = text
    title = first_user or last_user or last_assistant or "Claude Code Thread"
    project = path.parent.name
    return ClaudeSessionCandidate(
        session_id=session_id,
        title=title[:120],
        project=project,
        path=path,
        size=stat.st_size,
        updated_at=updated_at,
        message_count=message_count,
    )


def claude_session_candidates(claude_home: Path, older_than_days: int) -> list[ClaudeSessionCandidate]:
    projects_root = claude_home / "projects"
    if not projects_root.exists():
        return []
    cutoff = time.time() - older_than_days * 24 * 60 * 60
    candidates: list[ClaudeSessionCandidate] = []
    for path in projects_root.glob("*/*.jsonl"):
        try:
            if path.stat().st_mtime >= cutoff:
                continue
        except OSError:
            continue
        summary = summarize_claude_session(path)
        if summary:
            candidates.append(summary)
    candidates.sort(key=lambda item: item.updated_at, reverse=True)
    return candidates


def archive_selected_claude_sessions(
    claude_home: Path,
    backup_root: Path,
    selected_session_ids: list[str],
    include_all_old: bool,
    older_than_days: int,
    apply: bool,
    details: bool,
) -> None:
    candidates = claude_session_candidates(claude_home, older_than_days)
    total = sum(item.size for item in candidates)
    report(f"claude_session_candidates {len(candidates)}")
    report(f"claude_session_candidate_mb {mb(total)}")
    selected_ids = {item.strip() for item in selected_session_ids if item.strip()}
    for index, item in enumerate(candidates[:20], start=1):
        label = f"claude_session_{index:03d}"
        title = " ".join(item.title.split())[:120]
        if details:
            report(f"claude_session_mb {mb(item.size)} {label} session_id={item.session_id} messages={item.message_count} project={item.project} title={title} path={item.path}")
        else:
            report(f"claude_session_mb {mb(item.size)} {label} session_id={item.session_id} messages={item.message_count} title={title}")
    if not apply:
        return
    selected = [item for item in candidates if include_all_old or item.session_id in selected_ids or str(item.path) in selected_ids]
    report(f"claude_sessions_selected {len(selected)}")
    if not selected:
        return
    archive_root = claude_home / "archived-dexrelay-sessions" / now_stamp()
    manifest = backup_root / "archived-claude-sessions.jsonl"
    archive_root.mkdir(parents=True, exist_ok=True)
    manifest.parent.mkdir(parents=True, exist_ok=True)
    moved = 0
    with manifest.open("w", encoding="utf-8") as handle:
        for item in selected:
            project_archive = archive_root / re.sub(r"[^A-Za-z0-9._-]+", "-", item.project)
            project_archive.mkdir(parents=True, exist_ok=True)
            dest = project_archive / item.path.name
            record = {
                "session_id": item.session_id,
                "title": item.title,
                "from": str(item.path),
                "to": str(dest),
                "bytes": item.size,
                "project": item.project,
            }
            try:
                shutil.move(str(item.path), str(dest))
                companion = item.path.with_suffix("")
                if companion.exists() and companion.is_dir():
                    companion_dest = project_archive / companion.name
                    shutil.move(str(companion), str(companion_dest))
                    record["companion_to"] = str(companion_dest)
                session_env = claude_home / "session-env" / item.session_id
                if session_env.exists():
                    session_env_dest = project_archive / f"session-env-{item.session_id}"
                    shutil.move(str(session_env), str(session_env_dest))
                    record["session_env_to"] = str(session_env_dest)
                record["archived"] = True
                moved += 1
                archived_title = " ".join(item.title.split())[:120]
                report(f"claude_session_archived session_id={item.session_id} title={archived_title} path={dest}")
            except OSError as exc:
                record["archived"] = False
                record["error"] = str(exc)
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    report(f"claude_sessions_archived {moved}")
    report(f"claude_sessions_archive_root {archive_root}")
    report(f"claude_sessions_manifest {manifest}")


def rotate_logs(codex_home: Path, threshold_mb: int, stamp: str, apply: bool) -> None:
    files = [path for path in codex_home.glob("logs_2.sqlite*") if path.is_file()]
    total = sum(path.stat().st_size for path in files)
    report(f"logs_mb {mb(total)}")
    if total < threshold_mb * 1024 * 1024:
        report("logs_rotate skipped_below_threshold")
        return
    if apply and files:
        archive_root = codex_home / "archived_logs" / f"keep-codex-fast-{stamp}"
        archive_root.mkdir(parents=True, exist_ok=True)
        for path in files:
            shutil.move(str(path), str(archive_root / path.name))
        report(f"logs_archive_root {archive_root}")


def top_node_processes(details: bool) -> None:
    system = platform.system()
    report("top_node_processes")
    try:
        if system == "Windows":
            command = (
                "Get-Process node -ErrorAction SilentlyContinue | "
                "Sort-Object WorkingSet64 -Descending | Select-Object -First 10 "
                "Id,ProcessName,@{n='MB';e={[math]::Round($_.WorkingSet64/1MB,1)}},Path | "
                "ConvertTo-Json -Compress"
            )
            output = subprocess.check_output(["powershell", "-NoProfile", "-Command", command], text=True)
            if not output.strip():
                return
            data = json.loads(output)
            rows = data if isinstance(data, list) else [data]
            for row in rows:
                if details:
                    report(f"node_mb {row.get('MB')} pid={row.get('Id')} path={row.get('Path')}")
                else:
                    report(f"node_mb {row.get('MB')} process=node")
            return
        output = subprocess.check_output(["ps", "-axo", "pid=,rss=,comm=,args="], text=True)
        rows = []
        for line in output.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) >= 3 and "node" in parts[2].lower():
                rows.append((int(parts[1]), line.strip()))
        for rss, line in sorted(rows, reverse=True)[:10]:
            if details:
                report(f"node_mb {rss / 1024:.1f} {line}")
            else:
                report(f"node_mb {rss / 1024:.1f} process=node")
    except Exception as exc:
        report(f"node_process_report_skipped {exc}")


def verify_sizes(codex_home: Path) -> None:
    for rel in ["sessions", "archived_sessions", "worktrees", "archived_worktrees", "archived_logs"]:
        path = codex_home / rel
        if path.exists():
            report(f"size_{rel}_gb {gb(size_bytes(path))}")


def run(args: argparse.Namespace) -> int:
    codex_home = codex_home_from_args(args.codex_home)
    claude_home = claude_home_from_args(args.claude_home)
    if not codex_home.exists():
        report(f"codex_home_missing {codex_home}")
        return 2

    stamp = now_stamp()
    backup_root = Path(args.backup_root).expanduser() if args.backup_root else documents_backup_root() / f"keep-codex-fast-{stamp}"
    backup_root = backup_root.resolve()

    running = codex_processes_running()
    if args.apply and running and args.wait_for_codex_exit:
        report("waiting_for_codex_exit")
        wait_for_codex_exit()
        running = []

    effective_apply = bool(args.apply and not running)
    effective_backup = bool(effective_apply or args.backup_only)
    requested_mode = "apply" if args.apply else "backup-only" if args.backup_only else "report"
    effective_mode = "apply" if effective_apply else "backup-only" if effective_backup else "report"
    if args.details:
        report(f"codex_home {codex_home}")
        if effective_backup:
            report(f"backup_root {backup_root}")
    elif effective_backup:
        report(f"backup_root {backup_root}")
    report(f"requested_mode {requested_mode}")
    report(f"effective_mode {effective_mode}")
    if effective_mode == "report":
        report("mode_safety read_only=true privacy=pseudonymous")
    elif effective_mode == "backup-only":
        report("mode_safety backup_only=true archives=false state_writes=false")
    else:
        report("mode_safety backup_first=true archive_codex_state=true delete_stale_temp_builds=true")
    if args.apply and running:
        report("apply_skipped_codex_running")
        for index, proc in enumerate(running, start=1):
            if args.details:
                report(f"blocking_process {proc}")
            else:
                report(f"blocking_process codex_process_{index:03d}")

    if effective_backup:
        backup_metadata(codex_home, backup_root)

    state_db = codex_home / "state_5.sqlite"
    if state_db.exists():
        conn = sqlite_connect(state_db, readonly=not effective_apply)
        conn.execute("pragma busy_timeout=10000")
        normalize_sqlite_paths(conn, effective_apply)
        candidates = active_session_candidates(conn, codex_home, args.archive_older_than_days)
        archive_sessions(conn, candidates, codex_home, backup_root, stamp, effective_apply, args.details)
        if effective_apply:
            conn.commit()
            try:
                conn.execute("pragma wal_checkpoint(truncate)")
            except Exception as exc:
                report(f"wal_checkpoint_skipped {exc}")
            try:
                conn.execute("pragma optimize")
            except Exception as exc:
                report(f"sqlite_optimize_skipped {exc}")
        conn.close()
    else:
        report("state_db_missing")

    prune_config(codex_home, backup_root, effective_apply, effective_backup)
    move_stale_worktrees(codex_home, backup_root, args.worktree_older_than_days, stamp, effective_apply)
    clean_stale_temp_builds(backup_root, args.xcode_tmp_older_than_hours, effective_apply, args.details)
    archive_selected_claude_sessions(
        claude_home,
        backup_root,
        args.archive_claude_session,
        args.archive_all_old_claude_sessions,
        args.claude_session_older_than_days,
        effective_apply,
        args.details,
    )
    rotate_logs(codex_home, args.rotate_logs_above_mb, stamp, effective_apply)
    verify_sizes(codex_home)
    top_node_processes(args.details)
    report("done")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Safe, backup-first, archive-only Codex local-state maintenance."
    )
    parser.add_argument("--apply", action="store_true", help="Apply maintenance actions. Default is report-only.")
    parser.add_argument(
        "--backup-only",
        action="store_true",
        help="Create backups without applying maintenance actions. Default report mode writes no files.",
    )
    parser.add_argument(
        "--details",
        action="store_true",
        help="Include raw thread IDs, titles, paths, and process paths in output.",
    )
    parser.add_argument("--wait-for-codex-exit", action="store_true", help="Wait until Codex exits before applying.")
    parser.add_argument("--codex-home", help="Override Codex home. Defaults to CODEX_HOME or ~/.codex.")
    parser.add_argument("--claude-home", help="Override Claude home. Defaults to CLAUDE_CONFIG_DIR, CLAUDE_HOME, or ~/.claude.")
    parser.add_argument("--backup-root", help="Override backup output folder.")
    parser.add_argument("--archive-older-than-days", type=int, default=10)
    parser.add_argument("--worktree-older-than-days", type=int, default=7)
    parser.add_argument("--xcode-tmp-older-than-hours", type=int, default=24)
    parser.add_argument("--claude-session-older-than-days", type=int, default=10)
    parser.add_argument("--archive-claude-session", action="append", default=[], help="Claude session id or path to archive during --apply. Can be repeated.")
    parser.add_argument("--archive-all-old-claude-sessions", action="store_true", help="Archive every Claude session older than --claude-session-older-than-days during --apply.")
    parser.add_argument("--rotate-logs-above-mb", type=int, default=64)
    args = parser.parse_args(argv)
    if args.apply and args.backup_only:
        parser.error("--apply and --backup-only cannot be used together")
    return args


if __name__ == "__main__":
    raise SystemExit(run(parse_args(sys.argv[1:])))
