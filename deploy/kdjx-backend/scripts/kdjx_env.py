"""Strict parser shared by the KDJX private environment validators."""

from __future__ import print_function

import re


KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*")


def parse_environment(path, label="environment"):
    values = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw_line:
            raise ValueError("{}_line_{}_invalid".format(label, number))
        key, value = raw_line.split("=", 1)
        if key != key.strip() or not KEY_RE.fullmatch(key):
            raise ValueError("{}_line_{}_invalid".format(label, number))
        if key in values:
            raise ValueError("{}_duplicate_key".format(label))
        if value != value.strip() or "\x00" in value:
            raise ValueError("{}_line_{}_invalid".format(label, number))
        values[key] = value
    return values
