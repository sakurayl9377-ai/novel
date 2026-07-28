#!/usr/bin/env python3
"""Build the KDJX GM item allow-list from the generated items.lua table."""

from __future__ import print_function

import argparse
import ast
import hashlib
import json
import re
import sys
from pathlib import Path


TABLE_MARKER = "csv['items'] = {"
ENTRY_RE = re.compile(
    r"^\t\[(\d+)\] = \{\r?\n(.*?)(?=^\t\[\d+\] = \{|\r?\n\t__size = )",
    re.MULTILINE | re.DOTALL,
)
NAME_RE = re.compile(r"^\t\tname = ('(?:\\.|[^'])*'),\s*$", re.MULTILINE)
DESCRIPTION_RE = re.compile(
    r"^\t\tdesc = ('(?:\\.|[^'])*'),\s*$",
    re.MULTILINE,
)
INTEGER_FIELDS = {
    "quality": re.compile(r"^\t\tquality = (\d+),\s*$", re.MULTILINE),
    "type": re.compile(r"^\t\ttype = (\d+),\s*$", re.MULTILINE),
    "stackMax": re.compile(r"^\t\tstackMax = (\d+),\s*$", re.MULTILINE),
}
HIDDEN_RE = re.compile(r"^\t\tisShow = false,\s*$", re.MULTILINE)
INTERNAL_ITEM_RE = re.compile(r"测试|\btest(?:ing)?\b", re.IGNORECASE)


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def parse_lua_string(value):
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError) as exc:
        fail("invalid item name literal: {}".format(exc))
    if not isinstance(parsed, str):
        fail("item name must be text")
    return parsed.strip()


def safe_description(value):
    if not value:
        return ""
    result = re.sub(r"[\x00-\x1f\x7f]+", " ", parse_lua_string(value))
    return re.sub(r"\s+", " ", result).strip()[:240]


def integer_field(body, name, default):
    match = INTEGER_FIELDS[name].search(body)
    return int(match.group(1)) if match else default


def build_catalog(source):
    try:
        payload = source.read_bytes()
        text = payload.decode("utf-8")
    except (OSError, UnicodeError) as exc:
        fail("unable to read items.lua: {}".format(exc))

    marker = text.find(TABLE_MARKER)
    if marker < 0:
        fail("items.lua table marker is missing")
    table = text[marker + len(TABLE_MARKER):]
    items = []
    seen = set()
    for match in ENTRY_RE.finditer(table):
        item_id = int(match.group(1))
        body = match.group(2)
        id_match = re.search(r"^\t\tid = (\d+),\s*$", body, re.MULTILINE)
        name_match = NAME_RE.search(body)
        if not id_match or int(id_match.group(1)) != item_id or not name_match:
            fail("item entry {} is malformed".format(item_id))
        if item_id in seen:
            fail("duplicate item id {}".format(item_id))
        seen.add(item_id)
        name = parse_lua_string(name_match.group(1))
        if not name or HIDDEN_RE.search(body) or INTERNAL_ITEM_RE.search(name):
            continue
        description_match = DESCRIPTION_RE.search(body)
        stack_max = integer_field(body, "stackMax", 9999)
        items.append(
            {
                "id": item_id,
                "name": name,
                "description": safe_description(
                    description_match.group(1) if description_match else ""
                ),
                "type": integer_field(body, "type", 0),
                "quality": integer_field(body, "quality", 1),
                "maxQuantity": max(1, min(stack_max, 9999)),
            }
        )

    declared = re.search(r"\r?\n\t__size = (\d+),", table)
    if not declared:
        fail("items.lua declared size is missing")
    source_count = int(declared.group(1))
    if len(seen) != source_count:
        fail(
            "items.lua entry count mismatch: parsed {}, declared {}".format(
                len(seen), source_count
            )
        )
    if not items:
        fail("item catalog is empty")
    return {
        "schemaVersion": 1,
        "source": "KDJX generated items.lua",
        "sourceSha256": hashlib.sha256(payload).hexdigest(),
        "sourceItemCount": source_count,
        "itemCount": len(items),
        "items": sorted(items, key=lambda item: (item["type"], item["id"])),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--items-lua", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    source = Path(args.items_lua).resolve()
    output = Path(args.output).resolve()
    catalog = build_catalog(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        "KDJX GM item catalog written: {} items ({})".format(
            catalog["itemCount"], output
        )
    )


if __name__ == "__main__":
    main()
