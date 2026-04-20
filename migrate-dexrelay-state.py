#!/usr/bin/env python3
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


DEXRELAY_FILE_NAMES = {
    "project-runbook.json",
    "project-governance.json",
    "project-planning.md",
    "exportOptions-debug.plist",
}

DEXRELAY_DIRECTORY_NAMES = {
    "app-screenshot-studio",
    "artifacts",
    "logs",
    "build",
}


def is_dexrelay_owned(path: Path) -> bool:
    if path.name in DEXRELAY_FILE_NAMES:
        return True
    if path.name in DEXRELAY_DIRECTORY_NAMES:
        return True
    return path.suffix == ".pid"


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def merge_directory(src: Path, dst: Path, moved: list[tuple[Path, Path]]) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for child in sorted(src.iterdir(), key=lambda item: item.name):
        child_dst = dst / child.name
        move_entry(child, child_dst, moved)
    if src.exists():
        src.rmdir()


def move_entry(src: Path, dst: Path, moved: list[tuple[Path, Path]]) -> None:
    if src.is_dir():
        if dst.exists() and dst.is_dir():
            merge_directory(src, dst, moved)
            return
        ensure_parent(dst)
        shutil.move(str(src), str(dst))
        moved.append((src, dst))
        return

    if dst.exists():
        if dst.is_file():
            dst.unlink()
        else:
            shutil.rmtree(dst)
    ensure_parent(dst)
    shutil.move(str(src), str(dst))
    moved.append((src, dst))


def migrate_codex_directory(codex_dir: Path) -> list[tuple[Path, Path]]:
    dexrelay_dir = codex_dir.parent / ".dexrelay"
    moved: list[tuple[Path, Path]] = []

    for entry in sorted(codex_dir.iterdir(), key=lambda item: item.name):
        if not is_dexrelay_owned(entry):
            continue
        move_entry(entry, dexrelay_dir / entry.name, moved)

    return moved


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Move DexRelay-owned project state from .codex to .dexrelay across a source tree."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=str(Path.home() / "src"),
        help="Root directory to scan. Defaults to ~/src.",
    )
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    if not root.exists():
        raise SystemExit(f"Root does not exist: {root}")

    total_moves: list[tuple[Path, Path]] = []
    touched_dirs = 0

    for codex_dir in sorted(root.rglob(".codex")):
        if not codex_dir.is_dir():
            continue
        moved = migrate_codex_directory(codex_dir)
        if moved:
            touched_dirs += 1
            total_moves.extend(moved)

    for src, dst in total_moves:
        print(f"MOVED {src} -> {dst}")

    print(f"\nTouched .codex directories: {touched_dirs}")
    print(f"Moved entries: {len(total_moves)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
