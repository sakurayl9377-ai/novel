#!/usr/bin/env python3
"""Validate the production KDJX login patch descriptor set."""

from __future__ import print_function

import argparse
import json
import re
import sys
from pathlib import Path


# These descriptors are the active production upgrade chain. In particular,
# fresh APKs carry patch 17, while older installed clients can still report
# any earlier published baseline represented here.
REQUIRED_PATCH_DESCRIPTORS = (8, 9, 11, 12, 13, 14, 15, 16, 17)
DESCRIPTOR_NAME = re.compile(r"^([1-9][0-9]*)\.json$")


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def read_descriptor_numbers(patch_root):
    patch_root = Path(patch_root)
    channel_root = patch_root / "cn"
    if not channel_root.is_dir() or channel_root.is_symlink():
        fail("login patch root must contain a regular cn directory")

    descriptors = []
    for path in channel_root.iterdir():
        match = DESCRIPTOR_NAME.match(path.name)
        if not match:
            continue
        if path.is_symlink() or not path.is_file():
            fail("login patch descriptor must be a regular file: {}".format(path.name))
        number = int(match.group(1))
        if path.name != "{}.json".format(number):
            fail("login patch descriptor name is not canonical: {}".format(path.name))
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            fail("login patch descriptor is invalid JSON: {} ({})".format(path.name, exc))
        if not isinstance(value, dict) or not isinstance(value.get("files"), list):
            fail("login patch descriptor has an invalid files catalog: {}".format(path.name))
        descriptors.append(number)

    if not descriptors:
        fail("login patch source contains no numeric descriptors")
    return tuple(sorted(descriptors))


def require_production_descriptors(numbers):
    available = set(numbers)
    missing = [
        "{}.json".format(number)
        for number in REQUIRED_PATCH_DESCRIPTORS
        if number not in available
    ]
    if missing:
        fail("required login patch descriptors are missing: {}".format(", ".join(missing)))


def validate(source_root, candidate_root=None):
    source_numbers = read_descriptor_numbers(source_root)
    require_production_descriptors(source_numbers)
    if candidate_root is not None:
        candidate_numbers = read_descriptor_numbers(candidate_root)
        if candidate_numbers != source_numbers:
            missing = sorted(set(source_numbers) - set(candidate_numbers))
            added = sorted(set(candidate_numbers) - set(source_numbers))
            details = []
            if missing:
                details.append(
                    "missing {}".format(", ".join("{}.json".format(number) for number in missing))
                )
            if added:
                details.append(
                    "added {}".format(", ".join("{}.json".format(number) for number in added))
                )
            fail(
                "login patch descriptor set was not preserved: {}".format(
                    "; ".join(details) or "descriptor order changed"
                )
            )
    return source_numbers


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--candidate")
    args = parser.parse_args()

    numbers = validate(args.source, args.candidate)
    print(
        "KDJX login patch descriptors verified: {}".format(
            ", ".join(str(number) for number in numbers)
        )
    )


if __name__ == "__main__":
    main()
