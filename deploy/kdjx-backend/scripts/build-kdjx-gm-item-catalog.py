#!/usr/bin/env python3
"""Build the KDJX GM item allow-list from generated game configuration."""

from __future__ import print_function

import argparse
import ast
import hashlib
import json
import re
import sys
from pathlib import Path


TABLE_MARKER = "csv['items'] = {"
ROLE_FIGURE_TABLE_MARKER = "csv['role_figure'] = {"
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
INTERNAL_ITEM_RE = re.compile(r"测试|\btest(?:ing)?\b", re.IGNORECASE)
FIGURE_ENTRY_RE = re.compile(
    r"^\t\[(\d+)\] = \{\r?\n(.*?)(?=^\t\[\d+\] = \{|\r?\n\t__size = )",
    re.MULTILINE | re.DOTALL,
)
FIGURE_NAME_RE = re.compile(r"^\t\tname = ('(?:\\.|[^'])*'),\s*$", re.MULTILINE)
FIGURE_COST_RE = re.compile(
    r"^\t\tactiveCost = \{\[(\d+)\] = (\d+), __size = \d+\},\s*$",
    re.MULTILINE,
)
RESOURCE_ITEMS = {
    400: ("冒险家经验", "发放后按游戏经验规则结算", 2147483647),
    401: ("金币", "游戏内金币", 2147483647),
    402: ("钻石", "游戏内钻石，不计入充值", 2147483647),
    403: ("体力", "游戏内体力", 2147483647),
    900000001: ("技能点", "游戏技能点（skill_point）", 2147483647),
    900000002: ("天赋点", "游戏天赋点（talent_point）", 2147483647),
    900000003: ("装备觉醒碎片", "游戏装备觉醒碎片（equip_awake_frag）", 2147483647),
    900000004: ("道馆天赋点", "游戏道馆天赋点（gym_talent_point）", 2147483647),
    900000005: ("特殊货币 1", "游戏活动货币（coin1）", 2147483647),
    900000006: ("特殊货币 2", "游戏活动货币（coin2）", 2147483647),
    900000007: ("特殊货币 3", "游戏活动货币（coin3）", 2147483647),
    900000008: ("特殊货币 4", "游戏活动货币（coin4）", 2147483647),
    900000009: ("特殊货币 5", "游戏活动货币（coin5）", 2147483647),
    900000010: ("特殊货币 6", "游戏活动货币（coin6）", 2147483647),
    900000011: ("特殊货币 7", "历史活动货币（coin7，登录时会自动转换）", 2147483647),
    900000012: ("特殊货币 8", "游戏活动货币（coin8）", 2147483647),
    900000013: ("特殊货币 9", "历史活动货币（coin9，登录时会自动转换）", 2147483647),
    900000014: ("特殊货币 10", "游戏活动货币（coin10）", 2147483647),
    900000015: ("特殊货币 11", "游戏活动货币（coin11）", 2147483647),
    900000016: ("特殊货币 12", "游戏活动货币（coin12）", 2147483647),
    900000017: ("特殊货币 13", "游戏活动货币（coin13）", 2147483647),
    900000018: ("特殊货币 14", "游戏活动货币（coin14）", 2147483647),
}
RESERVED_VIRTUAL_ITEM_IDS = frozenset(range(404, 430))


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


def build_catalog(source, role_figure_source=None):
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
        if (
            not name
            or item_id in RESERVED_VIRTUAL_ITEM_IDS
            or INTERNAL_ITEM_RE.search(name)
        ):
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
    by_id = {item["id"]: item for item in items}
    for item_id, (name, description, maximum) in RESOURCE_ITEMS.items():
        item = by_id.get(item_id)
        if item is None:
            item = {
                "id": item_id,
                "name": name,
                "description": description,
                "type": 0,
                "quality": 1,
                "maxQuantity": maximum,
            }
            items.append(item)
            by_id[item_id] = item
        else:
            item["maxQuantity"] = maximum

    figure_payload = b""
    if role_figure_source:
        try:
            figure_payload = role_figure_source.read_bytes()
        except OSError as exc:
            fail("unable to read role_figure.lua: {}".format(exc))
        items.extend(build_figure_tokens(role_figure_source, by_id))
    if not items:
        fail("item catalog is empty")
    return {
        "schemaVersion": 1,
        "source": "KDJX generated items.lua and role_figure.lua",
        "sourceSha256": hashlib.sha256(
            payload + b"\0" + figure_payload
        ).hexdigest(),
        "sourceItemCount": source_count,
        "itemCount": len(items),
        "items": sorted(items, key=lambda item: (item["type"], item["id"])),
    }


def build_figure_tokens(source, known_items):
    try:
        text = source.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail("unable to read role_figure.lua: {}".format(exc))
    marker = text.find(ROLE_FIGURE_TABLE_MARKER)
    if marker < 0:
        fail("role_figure.lua table marker is missing")
    table = text[marker + len(ROLE_FIGURE_TABLE_MARKER):]
    tokens = []
    token_ids = set()
    for match in FIGURE_ENTRY_RE.finditer(table):
        name_match = FIGURE_NAME_RE.search(match.group(2))
        cost_match = FIGURE_COST_RE.search(match.group(2))
        if not name_match or not cost_match:
            continue
        token_id = int(cost_match.group(1))
        if token_id in known_items or token_id in token_ids:
            continue
        figure_name = parse_lua_string(name_match.group(1))
        if not figure_name or INTERNAL_ITEM_RE.search(figure_name):
            continue
        token_ids.add(token_id)
        tokens.append({
            "id": token_id,
            "name": "{}的信物".format(figure_name),
            "description": "用于解锁形象【{}】".format(figure_name),
            "type": 0,
            "quality": 5,
            "maxQuantity": 1,
        })
    return tokens


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--items-lua", required=True)
    parser.add_argument("--role-figure-lua", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    source = Path(args.items_lua).resolve()
    output = Path(args.output).resolve()
    figure_source = Path(args.role_figure_lua).resolve()
    catalog = build_catalog(source, figure_source)
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
