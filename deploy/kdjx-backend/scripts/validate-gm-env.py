#!/usr/bin/env python3
"""Validate the login-only KDJX GM environment without exposing secrets."""

from __future__ import print_function

import argparse
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from kdjx_env import parse_environment


EXPECTED_CATALOG = "/opt/kdjx/runtime/current/kdjx-gm-item-catalog.json"
REQUIRED_KEYS = frozenset({
    "KDJX_GM_HMAC_SECRET",
    "KDJX_GM_ITEM_CATALOG_FILE",
})


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def validate_file_metadata(path):
    try:
        metadata = path.stat()
    except OSError as exc:
        fail("gm_env_unreadable: {}".format(exc))
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail("gm_env_file_invalid")
    if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("gm_env_permissions_invalid")


def validate_values(values):
    if set(values) != REQUIRED_KEYS:
        raise ValueError("gm_env_keys_invalid")
    secret = values.get("KDJX_GM_HMAC_SECRET", "")
    if len(secret) < 32 or secret.startswith("REPLACE_"):
        raise ValueError("gm_env_secret_invalid")
    if values.get("KDJX_GM_ITEM_CATALOG_FILE") != EXPECTED_CATALOG:
        raise ValueError("gm_env_catalog_invalid")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", default="/etc/kdjx/gm.env")
    args = parser.parse_args()
    path = Path(args.env_file)
    validate_file_metadata(path)
    try:
        values = parse_environment(path, "gm_env")
        validate_values(values)
    except (OSError, UnicodeError, ValueError) as exc:
        fail(str(exc))
    print("KDJX GM environment policy passed.")


if __name__ == "__main__":
    main()
