#!/usr/bin/env python3
"""Repack a Sakura KDJX APK with a complete, verified hot-update snapshot."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import build_kdjx_client as builder


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apk",
        type=Path,
        required=True,
        help="Existing Sakura APK with the bridge dex; never modified in place",
    )
    parser.add_argument(
        "--patch-root",
        type=Path,
        required=True,
        help="Complete numbered patch directory, such as hot-staging/17",
    )
    parser.add_argument(
        "--patch-catalog",
        type=Path,
        required=True,
        help="Catalog matching --patch-root, such as login-patch/cn/17.json",
    )
    parser.add_argument("--hot-version", required=True)
    parser.add_argument("--login-patch", required=True)
    parser.add_argument("--apk-version-code", required=True)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="New, dedicated output directory",
    )
    parser.add_argument("--game-origin", default=builder.DEFAULT_GAME_ORIGIN)
    parser.add_argument("--apktool", help="Path to apktool executable/cmd")
    parser.add_argument("--android-jar", help="Path to an Android platform android.jar")
    parser.add_argument("--d8", help="Path to Android d8 executable/cmd")
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace an output directory created by this script",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        apk = args.apk.resolve()
        patch_root = args.patch_root.resolve()
        patch_catalog = args.patch_catalog.resolve()
        version = builder.hot_version(args.hot_version)
        target_patch = builder.login_patch(args.login_patch)
        target_version_code = builder.apk_version_code(args.apk_version_code)
        source_patch = builder.source_apk_login_patch(apk)
        if int(target_patch) <= int(source_patch):
            builder.fail(f"login_patch_must_exceed_source_apk_patch_{source_patch}")

        game_origin = builder.owned_game_origin(args.game_origin)
        api_origin = builder.owned_api_origin(builder.DEFAULT_API_ORIGIN)
        output = args.output.resolve()
        builder.prepare_output(output, args.force)
        apktool = builder.resolve_tool(
            args.apktool,
            ("apktool.cmd", "apktool"),
            (Path(r"E:\tools\apk-reverse\bin\apktool.cmd"),),
        )
        android_jar = builder.find_android_jar(args.android_jar)
        d8 = builder.resolve_tool(
            args.d8,
            ("d8.bat", "d8"),
            (Path(r"G:\Android\Sdk\cmdline-tools\latest\bin\d8.bat"),),
        )

        unsigned_apk = output / "kdjx-sakura-embedded-patch-unsigned.apk"
        builder.build_apk(
            apk,
            unsigned_apk,
            game_origin,
            api_origin,
            builder.version_plist(game_origin, target_patch),
            target_version_code,
            apktool,
            android_jar,
            d8,
            refresh_existing_bridge=True,
            bundled_patch_catalog=patch_catalog,
            bundled_patch_root=patch_root,
            bundled_patch_number=target_patch,
            bundled_patch_version=version,
        )
        bundle = builder.verify_bundled_patch_archive(
            unsigned_apk,
            patch_catalog,
            patch_root,
            target_patch,
            version,
        )
        endpoint_violations = builder.zip_entry_violations(unsigned_apk)
        if endpoint_violations:
            builder.fail(
                "forbidden_runtime_endpoint:" + ",".join(endpoint_violations)
            )

        report = {
            "ok": True,
            "sourceApkSha256": builder.sha256(apk),
            "sourceApkLoginPatch": source_patch,
            "apkSha256": builder.sha256(unsigned_apk),
            "apkVersionCode": target_version_code,
            "hotVersion": version,
            "loginPatch": target_patch,
            "bundledPatch": bundle,
            "gameOrigin": game_origin,
            "apiOrigin": api_origin,
            "generatedAt": int(time.time()),
            "unsignedApk": unsigned_apk.name,
        }
        builder.write_text(
            output / "verification.json",
            json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        )
        print(json.dumps(report, ensure_ascii=False))
        return 0
    except builder.BuildError as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
