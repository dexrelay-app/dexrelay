#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

from ios_testflight_common import detect_scheme, ensure_bundle_id, ensure_internal_groups, existing_bundle_ids, fetch_signing_profiles, find_first_xcodeproj, next_build_number, parse_build_settings, prepare_asc_cwd, resolve_app_record


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare an iOS Xcode project for TestFlight on App Store Connect.")
    parser.add_argument("--project", help="Path to the .xcodeproj file")
    parser.add_argument("--scheme", help="Shared Xcode scheme to use")
    parser.add_argument("--app-id", help="Explicit App Store Connect app ID", default="")
    parser.add_argument("--groups", help="Comma-separated TestFlight group names to ensure", default="")
    parser.add_argument(
        "--signing-output-dir",
        help="Directory where fetched signing assets should be written",
        default=".asc/signing/testflight-prep",
    )
    args = parser.parse_args()

    project_dir = Path.cwd()
    project_file = Path(args.project).expanduser().resolve() if args.project else None
    if project_file is None:
        found = find_first_xcodeproj(project_dir)
        if found is None:
            raise RuntimeError(f"No .xcodeproj found under {project_dir}")
        project_file = found.resolve()

    scheme = args.scheme.strip() if args.scheme else detect_scheme(project_file)
    if not scheme:
        raise RuntimeError(f"No shared scheme detected for {project_file.name}")

    settings = parse_build_settings(project_file, scheme)
    main_target = settings["main"]
    bundle_rows = settings["all"]

    asc_temp_dir, _ = prepare_asc_cwd(project_dir)
    asc_cwd = asc_temp_dir or project_dir

    try:
        bundle_cache = existing_bundle_ids(asc_cwd)
        bundle_states: list[dict[str, str]] = []
        for row in bundle_rows:
            target_name = row["target"] or row["product_name"] or scheme
            bundle_id, state = ensure_bundle_id(asc_cwd, row["bundle_id"], target_name, bundle_cache)
            bundle_states.append(
                {
                    "bundle_id": row["bundle_id"],
                    "target": row["target"],
                    "wrapper": row["wrapper"],
                    "developer_id": bundle_id,
                    "state": state,
                }
            )

        app_id, app = resolve_app_record(asc_cwd, main_target["bundle_id"], args.app_id.strip() or None)

        group_names = [item.strip() for item in args.groups.split(",") if item.strip()]
        if not group_names:
            group_names = ["Internal Testers"]

        groups: list[dict[str, str]] = []
        signing_warnings: list[str] = []
        next_build: str | None = None

        if app_id:
            groups = ensure_internal_groups(asc_cwd, app_id, group_names)
            signing_root = (project_dir / args.signing_output_dir).resolve()
            signing_warnings = fetch_signing_profiles(
                asc_cwd,
                [row["bundle_id"] for row in bundle_rows],
                signing_root,
            )
            next_build = next_build_number(
                asc_cwd,
                app_id,
                main_target["marketing_version"] or "1.0",
                main_target["build_number"] or "1",
            )

        app_name = ((app or {}).get("attributes") or {}).get("name") if app else None
        app_name = str(app_name or main_target["product_name"] or scheme).strip()

        print(f"Prepared TestFlight context for {app_name}")
        print(f"Project: {project_file}")
        print(f"Scheme: {scheme}")
        print(f"Release bundle ID: {main_target['bundle_id']}")
        print(f"Release version: {main_target['marketing_version'] or 'unknown'} ({main_target['build_number'] or 'unknown'})")
        if main_target["development_team"]:
            print(f"Apple team: {main_target['development_team']}")
        print("")
        print("Bundle IDs:")
        for row in bundle_states:
            print(f"- {row['bundle_id']} [{row['wrapper']}] ({row['state']})")

        if not app_id:
            suggested_sku = re.sub(r"[^a-z0-9]+", "-", main_target["bundle_id"].lower()).strip("-")
            suggested_sku = f"{suggested_sku}-{project_dir.stat().st_mtime_ns % 10_000}"
            print("")
            print("App Store Connect app record: missing")
            print("Manual step remaining:")
            print(f"- Create the app in App Store Connect with bundle ID `{main_target['bundle_id']}`")
            print(f"- Suggested name: `{app_name}`")
            print(f"- Suggested SKU: `{suggested_sku}`")
            return 0

        print("")
        print(f"App Store Connect app ID: {app_id}")
        print(f"App Store Connect URL: https://appstoreconnect.apple.com/apps/{app_id}")
        print(f"TestFlight URL: https://appstoreconnect.apple.com/apps/{app_id}/testflight/ios")

        print("")
        print("Internal TestFlight groups:")
        for group in groups:
            print(f"- {group['name']} ({group['id']}) [{group['state']}]")

        if next_build:
            print("")
            print(f"Next safe TestFlight build number: {next_build}")

        if signing_warnings:
            print("")
            print("Signing fetch warnings:")
            for warning in signing_warnings:
                print(f"- {warning}")
        else:
            print("")
            print("Signing files prepared:")
            print(f"- {(project_dir / args.signing_output_dir).resolve()}")
    finally:
        if asc_temp_dir:
            shutil.rmtree(asc_temp_dir, ignore_errors=True)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # pragma: no cover
        print(str(exc), file=sys.stderr)
        sys.exit(1)
