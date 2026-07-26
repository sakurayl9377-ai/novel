#!/usr/bin/env python3
"""Materialize the minimal full-source input needed by build_kdjx_client.py.

KDJX's historical `patch/<number>/src/app.*` files are flattened release
artifacts, not a source tree. This helper copies only the Lua modules the
Sakura build transforms from a checked-out KDJX tree into a disposable input
directory. It never copies APKs, databases, server configuration, keys, or
legacy payment/admin files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path


REQUIRED_FILES = (
    "app/sdk/helper.lua",
    "app/sdk/init.lua",
    "app/views/login/view.lua",
    "app/game_app.lua",
    "app/defines/app_defines.lua",
)
MARKER = ".kdjx-client-source"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_source(root: Path) -> Path:
    root = root.resolve()
    candidates = (
        root,
        root / "application" / "src",
        root / "release" / "anti_cheat" / "game_scripts" / "application" / "src",
        root / "mnt" / "pokemon" / "release" / "anti_cheat" / "game_scripts" / "application" / "src",
    )
    for candidate in candidates:
        if candidate.is_dir() and all(
            candidate.joinpath(*item.split("/")).is_file()
            for item in REQUIRED_FILES
        ):
            return candidate
    raise ValueError("full_application_src_not_found")


def prepare(source: Path, output: Path, force: bool) -> None:
    if output.exists():
        if not force:
            raise ValueError("output_exists_use_force")
        if not (output / MARKER).is_file():
            raise ValueError("refusing_to_remove_unmarked_output")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    (output / MARKER).write_text("generated KDJX client source input\n", encoding="utf-8")

    files: list[dict[str, str]] = []
    for relative in REQUIRED_FILES:
        source_file = source.joinpath(*relative.split("/"))
        destination = output.joinpath(*relative.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source_file, destination)
        files.append({"path": relative, "sha256": sha256(destination)})
    (output / "source-manifest.json").write_text(
        json.dumps({"files": files}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kdjx-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    try:
        source = find_source(args.kdjx_root)
        prepare(source, args.output.resolve(), args.force)
        print(json.dumps({
            "ok": True,
            "source": str(source),
            "output": str(args.output.resolve()),
            "files": list(REQUIRED_FILES),
        }))
        return 0
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
