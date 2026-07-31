#!/usr/bin/env python3
"""Validate the committed KDJX GM item allow-list before staging it."""

from __future__ import print_function

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
ITEM_KEYS = frozenset({
    "id",
    "name",
    "description",
    "type",
    "quality",
    "maxQuantity",
})


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate_catalog(catalog):
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 1:
        raise ValueError("gm_catalog_schema_invalid")
    items = catalog.get("items")
    item_count = catalog.get("itemCount")
    source_count = catalog.get("sourceItemCount")
    source_hash = catalog.get("sourceSha256")
    if (
        not isinstance(items, list)
        or not items
        or len(items) > 5000
        or not is_integer(item_count)
        or item_count != len(items)
        or not is_integer(source_count)
        or source_count < 1
        or not isinstance(source_hash, str)
        or not SHA256_RE.fullmatch(source_hash)
    ):
        raise ValueError("gm_catalog_metadata_invalid")

    seen = set()
    for item in items:
        if not isinstance(item, dict) or set(item) != ITEM_KEYS:
            raise ValueError("gm_catalog_item_invalid")
        item_id = item.get("id")
        name = item.get("name")
        description = item.get("description")
        item_type = item.get("type")
        quality = item.get("quality")
        maximum = item.get("maxQuantity")
        if (
            not is_integer(item_id)
            or item_id <= 0
            or item_id in seen
            or not isinstance(name, str)
            or name != name.strip()
            or not name
            or len(name) > 128
            or any(ord(character) < 32 for character in name)
            or not isinstance(description, str)
            or description != description.strip()
            or len(description) > 240
            or any(ord(character) < 32 for character in description)
            or not is_integer(item_type)
            or item_type < 0
            or not is_integer(quality)
            or quality < 0
            or not is_integer(maximum)
            or maximum < 1
            or maximum > 2147483647
        ):
            raise ValueError("gm_catalog_item_invalid")
        seen.add(item_id)


def validate_source(catalog, items_lua, role_figure_lua):
    if (
        not items_lua.is_file()
        or items_lua.is_symlink()
        or not role_figure_lua.is_file()
        or role_figure_lua.is_symlink()
    ):
        raise ValueError("gm_catalog_source_invalid")
    builder_path = Path(__file__).with_name("build-kdjx-gm-item-catalog.py")
    spec = importlib.util.spec_from_file_location("kdjx_gm_catalog_builder", builder_path)
    if spec is None or spec.loader is None:
        raise ValueError("gm_catalog_builder_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    runtime_text = items_lua.read_text(encoding="utf-8")
    marker = runtime_text.find(module.TABLE_MARKER)
    if marker < 0:
        raise ValueError("gm_catalog_runtime_items_invalid")
    runtime_table = runtime_text[marker + len(module.TABLE_MARKER):]
    runtime_item_ids = {
        int(match.group(1)) for match in module.ENTRY_RE.finditer(runtime_table)
    }
    virtual_item_ids = set(module.RESOURCE_ITEMS)
    unsupported = sorted(
        item["id"]
        for item in catalog["items"]
        if item["id"] not in runtime_item_ids
        and item["id"] not in virtual_item_ids
    )
    if unsupported:
        raise ValueError("gm_catalog_runtime_item_missing")
    expected = module.build_catalog(items_lua, role_figure_lua)
    if catalog != expected:
        raise ValueError("gm_catalog_source_mismatch")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--items-lua", required=True)
    parser.add_argument("--role-figure-lua", required=True)
    args = parser.parse_args()
    path = Path(args.catalog)
    if not path.is_file() or path.is_symlink():
        fail("gm_catalog_file_invalid")
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
        validate_catalog(catalog)
        validate_source(
            catalog,
            Path(args.items_lua).resolve(),
            Path(args.role_figure_lua).resolve(),
        )
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        fail(str(exc))
    print("KDJX GM item catalog policy passed.")


if __name__ == "__main__":
    main()
