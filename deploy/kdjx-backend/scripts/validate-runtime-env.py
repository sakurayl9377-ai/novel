#!/usr/bin/env python3
"""Fail closed unless KDJX runtime variables match the owned topology."""

from __future__ import print_function

import argparse
import os
import re
import stat
import sys
from pathlib import Path


EXPECTED_VALUES = {
    "KDJX_RUNTIME_ROOT": "/opt/kdjx/runtime/current",
    "KDJX_NOVEL_API_URL": "http://127.0.0.1:3010/novel-api",
    "KDJX_MONGO_URI": "mongodb://127.0.0.1:27159",
    "KDJX_PYTHON_IMAGE": "kdjx-legacy-python:2.7",
}
SECRET_KEYS = {
    "KDJX_SSO_SHARED_SECRET",
    "KDJX_PAYMENT_HMAC_SECRET",
}
REQUIRED_KEYS = frozenset(set(EXPECTED_VALUES) | SECRET_KEYS)
KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*")


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def parse_environment(path):
    values = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw_line:
            fail("runtime_env_line_{}_invalid".format(number))
        key, value = raw_line.split("=", 1)
        if key != key.strip() or not KEY_RE.fullmatch(key):
            fail("runtime_env_line_{}_invalid".format(number))
        if key in values:
            fail("runtime_env_duplicate_key")
        if value != value.strip() or "\x00" in value:
            fail("runtime_env_line_{}_invalid".format(number))
        values[key] = value
    return values


def validate_values(values):
    if set(values) != REQUIRED_KEYS:
        raise ValueError("runtime_env_keys_invalid")
    for key, expected in EXPECTED_VALUES.items():
        if values.get(key) != expected:
            raise ValueError("runtime_env_{}_invalid".format(key.lower()))
    for key in SECRET_KEYS:
        value = values.get(key, "")
        if len(value) < 32 or value.startswith("REPLACE_"):
            raise ValueError("runtime_env_{}_invalid".format(key.lower()))


def validate_file_metadata(path):
    try:
        metadata = path.stat()
    except OSError as exc:
        fail("runtime_env_unreadable: {}".format(exc))
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        fail("runtime_env_file_invalid")
    if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) != 0o600:
        fail("runtime_env_permissions_invalid")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", default="/etc/kdjx/runtime.env")
    args = parser.parse_args()
    path = Path(args.env_file)
    validate_file_metadata(path)
    try:
        values = parse_environment(path)
        validate_values(values)
    except (OSError, UnicodeError, ValueError) as exc:
        fail(str(exc))
    print("KDJX runtime environment policy passed.")


if __name__ == "__main__":
    main()
