#!/usr/bin/env python3
"""Apply a narrow fail-closed Sakura-channel gate to a staged Go source tree."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


GATE = """\tif t.Channel != \"sakura\" {\n\t\treturn &taskCheckResponse{\n\t\t\tRet: false,\n\t\t\tErr: \"sakura_auth_required\",\n\t\t}\n\t}\n\n"""
MARKER = "\tlog.Infof(\"login channel `%s` tag `%s` guarder `%s`\", t.Channel, t.Tag, t.Guarder)\n\n"


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    path = root / "gosrc" / "tjgame" / "login" / "checkin" / "task" / "check.go"
    if not path.is_file():
        fail("KDJX login task source is missing: {}".format(path))

    content = path.read_text(encoding="utf-8")
    if 'if t.Channel != "sakura" {' in content:
        return
    if MARKER not in content:
        fail("KDJX login task source does not match the supported source layout")
    path.write_text(content.replace(MARKER, MARKER + GATE, 1), encoding="utf-8")


if __name__ == "__main__":
    main()
