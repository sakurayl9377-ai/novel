#!/usr/bin/env python3
"""Make copied KDJX Lua/Python inputs safe for the owned production topology.

This is intentionally a transformation rather than an audit exemption. The
legacy source bundle contains old developer endpoints in executable code,
comments, and vendored documentation. A release may contain only owned
endpoints, so every copied text input is normalized before the strict audit.
"""

from __future__ import print_function

import argparse
import ipaddress
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse
import re


PUBLIC_BACKEND_IP = "49.232.137.85"
DOWNLOAD_HOST = "novel.kxhub.xyz"
LOOPBACK_IP = "127.0.0.1"
WILDCARD_IP = "0.0.0.0"
OWNED_BASE = "https://49.232.137.85"
TEXT_SUFFIXES = {
    ".cfg",
    ".csv",
    ".css",
    ".conf",
    ".go",
    ".html",
    ".ini",
    ".json",
    ".js",
    ".lua",
    ".md",
    ".plist",
    ".properties",
    ".proto",
    ".py",
    ".rst",
    ".sh",
    ".text",
    ".toml",
    ".txt",
    ".xml",
    ".yaml",
    ".yml",
}
IPV4_RE = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])")
URL_RE = re.compile(r"(?:(?:https?|mongodb)://[^\s\"'<>]+)", re.IGNORECASE)
CREDENTIAL_URI_RE = re.compile(r"://[^/\s:@]+:[^@/\s]+@", re.IGNORECASE)
LEGACY_HOST_LITERAL_RE = re.compile(
    r"(?:tianji-game\.com|kuyangsh\.cn|um-game\.com|facebook\.com|discord\.gg|"
    r"play\.google\.com|url\.cn|bdqaa\.fogjr\.tdlhct\.zwzfp)",
    re.IGNORECASE,
)
LOCALHOST_RE = re.compile(r"\blocalhost\b", re.IGNORECASE)
GAME_NET_URLS = {
    "noticeUrl": OWNED_BASE + "/kdjx/notice",
    "versionUrl": OWNED_BASE + "/kdjx/version",
    "serverUrl": OWNED_BASE + "/kdjx/servers",
}
KDJX_GAME_VERSION = "2.1.0.0"
KDJX_GAME_VERSION_SOURCE = "gosrc/tjgame/login/diff/init.go"


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def is_text_file(path):
    return path.suffix.lower() in TEXT_SUFFIXES


def has_symlink(root):
    return any(path.is_symlink() for path in root.rglob("*"))


def valid_ipv4(value):
    try:
        return str(ipaddress.ip_address(value)) == value
    except ValueError:
        return False


def is_allowed_download_url(parsed):
    return (
        parsed.scheme == "https"
        and parsed.hostname == DOWNLOAD_HOST
        and parsed.port in (None, 443)
        and parsed.path.startswith("/games/kdjx/")
    )


def route_for_legacy_url(value):
    """Redirect a legacy URL to a harmless owned route, without its query."""
    trimmed = value.rstrip(".,;:)]}")
    suffix = value[len(trimmed) :]
    try:
        parsed = urlparse(trimmed)
    except ValueError:
        # Legacy source contains malformed URL literals too. They cannot be
        # retained or allowed to abort sanitization; route them to the same
        # inert owned acknowledgement used for unknown telemetry.
        return OWNED_BASE + "/kdjx/feedback" + suffix
    host = parsed.hostname
    allowed_hosts = {PUBLIC_BACKEND_IP, LOOPBACK_IP}
    if host in allowed_hosts and "access_token=" not in parsed.query.lower() and not parsed.username:
        return value
    if (
        is_allowed_download_url(parsed)
        and "access_token=" not in parsed.query.lower()
        and not parsed.username
    ):
        return value

    path = parsed.path.rstrip("/").lower()
    if "privacy" in path:
        replacement = OWNED_BASE + "/games/kdjx/privacy"
    elif "support" in path or "customer" in path:
        replacement = OWNED_BASE + "/games/kdjx/support"
    elif "telemetry" in path or "report" in path:
        replacement = OWNED_BASE + "/games/kdjx/telemetry/"
    elif path.endswith("/notice"):
        replacement = OWNED_BASE + "/kdjx/notice"
    elif path.endswith("/version"):
        replacement = OWNED_BASE + "/kdjx/version"
    elif path.endswith("/servers"):
        replacement = OWNED_BASE + "/kdjx/servers"
    else:
        # Do not redirect a legacy payment, crash report, or analytics request
        # to a real operation. The local endpoint deliberately returns 204.
        replacement = OWNED_BASE + "/kdjx/feedback"
    return replacement + suffix


def replace_game_net_assignments(text):
    for field, target in GAME_NET_URLS.items():
        text = re.sub(
            r"(self\.{0}\s*=\s*)['\"][^'\"]*['\"]".format(re.escape(field)),
            r"\1'{}'".format(target),
            text,
        )
    direct = {
        "loginAddress": "{}:16666".format(PUBLIC_BACKEND_IP),
        "loginHost": PUBLIC_BACKEND_IP,
        "gameHost": PUBLIC_BACKEND_IP,
    }
    for field, target in direct.items():
        text = re.sub(
            r"(self\.{0}\s*=\s*)['\"][^'\"]*['\"]".format(re.escape(field)),
            r"\1'{}'".format(target),
            text,
        )
    text = re.sub(r"(self\.gamePort\s*=\s*)\d+", r"\g<1>28879", text)
    return text


def replace_legacy_none_sdk(relative, text):
    if relative != "application/src/app/sdk/none.lua":
        return text
    # This file only exists in the anti-cheat Lua bundle. The shipped app has
    # its Sakura payment adapter injected separately. Never leave a usable
    # legacy payment fallback in a server-side runtime tree.
    return """-- Generated by deploy/kdjx-backend; legacy payment is disabled.\n\nlocal none = {}\n\nfunction none.commitRoleInfo(ctype, cb)\n\treturn cb()\nend\n\nfunction none._payOnline(cpOrderId, extInfo, amount, rechargeId, productDesc, cb)\n\treturn cb(-1, 'sakura_payment_required')\nend\n\nfunction none.pay(cpOrderId, extInfo, amount, rechargeId, productDesc, cb)\n\treturn cb(-1, 'sakura_payment_required')\nend\n\nfunction none.logout(cb)\n\treturn cb()\nend\n\nreturn none\n"""


def replace_known_lua_routes(relative, text):
    if relative.endswith("application/src/app/defines/app_defines.lua"):
        text = re.sub(
            r"(?m)^(\s*globals\.SUPPORT_URL\s*=\s*)[^\n]+",
            r"\1'{}'".format(OWNED_BASE + "/games/kdjx/support"),
            text,
        )
        for field in ("JUMP_SHOP_URL", "DISCORD_URL"):
            text = re.sub(
                r"(?m)^(\s*globals\.{0}\s*=\s*)[^\n]+".format(re.escape(field)),
                r"\1nil",
                text,
            )
    elif relative.endswith("application/src/app/sdk/init.lua"):
        text = re.sub(r"(?m)^\s*sdk\.ORDER_URL\s*=.*$", "sdk.ORDER_URL = nil", text)
        text = re.sub(r"(?m)^\s*sdk\.ORDER_SIGN_SECRET\s*=.*$", "sdk.ORDER_SIGN_SECRET = ''", text)
    elif relative.endswith("application/src/app/sdk/xy51.lua"):
        text = re.sub(
            r"(?m)^(\s*globals\.LOGIN_SERVRE_HOSTS_TABLE\s*=\s*)[^\n]+",
            r"\1{{'{}:16666'}}".format(PUBLIC_BACKEND_IP),
            text,
        )
    return text


def is_known_non_network_literal(relative, value, text, position):
    # Dotted file/game versions are not hosts. Keep each exception tied to its
    # exact source location (and, for Go, its assignment) so endpoints remain
    # fail-closed.
    if (
        relative.endswith("framework/MyLuaGame/cocos/cocostudio/CocoStudio.lua")
        and value == "1.0.0.0"
    ):
        return True
    if relative != KDJX_GAME_VERSION_SOURCE or value != KDJX_GAME_VERSION:
        return False
    line_start = text.rfind("\n", 0, position) + 1
    line_end = text.find("\n", position)
    if line_end < 0:
        line_end = len(text)
    return bool(
        re.fullmatch(
            r'\s*version\s*=\s*"2\.1\.0\.0"\s*(?://[^\r\n]*)?',
            text[line_start:line_end],
        )
    )


def redact_legacy_secrets(text):
    text = re.sub(
        r"(?i)(private[-_ ]token\s*[:=]\s*['\"]?)[^'\"\s,]+",
        r"\1REDACTED",
        text,
    )
    text = re.sub(
        r"(?i)(order_sign_secret\s*=\s*['\"])[^'\"]*",
        r"\1",
        text,
    )
    text = CREDENTIAL_URI_RE.sub("://REDACTED@", text)
    text = LEGACY_HOST_LITERAL_RE.sub("owned-host-redacted", text)
    text = LOCALHOST_RE.sub(LOOPBACK_IP, text)
    # Never retain a URL carrying an access token, even when it already uses
    # an owned host. route_for_legacy_url strips the query string.
    return text


def clean_text(relative, text, allow_wildcard):
    text = replace_legacy_none_sdk(relative, text)
    text = replace_known_lua_routes(relative, text)
    if relative.endswith("application/src/app/game_net.lua"):
        text = replace_game_net_assignments(text)
    text = redact_legacy_secrets(text)
    text = URL_RE.sub(lambda match: route_for_legacy_url(match.group(0)), text)
    allowed_ips = {PUBLIC_BACKEND_IP, LOOPBACK_IP}
    if allow_wildcard:
        allowed_ips.add(WILDCARD_IP)

    def replace_ip(match):
        value = match.group(0)
        if (
            not valid_ipv4(value)
            or value in allowed_ips
            or is_known_non_network_literal(relative, value, text, match.start())
        ):
            return value
        # The remaining occurrences are legacy configuration, comments, or
        # diagnostics. Loopback is a fail-closed target if an old branch is
        # unexpectedly executed.
        return LOOPBACK_IP

    return IPV4_RE.sub(replace_ip, text)


def clean_tree(root, allow_wildcard):
    for path in sorted(root.rglob("*")):
        if not path.is_file() or not is_text_file(path):
            continue
        relative = path.relative_to(root).as_posix()
        original = path.read_bytes()
        text = original.decode("utf-8", errors="surrogateescape")
        updated = clean_text(relative, text, allow_wildcard)
        if updated != text:
            path.write_bytes(updated.encode("utf-8", errors="surrogateescape"))


def copy_tree(source, destination):
    if not source.is_dir():
        fail("source directory does not exist: {}".format(source))
    if has_symlink(source):
        fail("source tree contains symlinks: {}".format(source))
    shutil.copytree(str(source), str(destination), copy_function=shutil.copy2)


def audit_bundle(audit_script, path):
    subprocess.run(
        [sys.executable, str(audit_script), "--bundle-root", str(path)],
        check=True,
    )


def prepare_inputs(args):
    patch_source = Path(args.patch_source).resolve()
    anti_source = Path(args.anti_cheat_source).resolve()
    output = Path(args.output).resolve()
    if output.exists() or output.is_symlink():
        fail("output already exists: {}".format(output))
    if not (patch_source / "cn").is_dir():
        fail("patch source must contain cn/: {}".format(patch_source))

    copy_tree(patch_source, output / "patch")
    copy_tree(anti_source, output / "anti-cheat-scripts")
    clean_tree(output / "patch", allow_wildcard=False)
    clean_tree(output / "anti-cheat-scripts", allow_wildcard=False)
    audit_script = Path(args.audit_script).resolve()
    audit_bundle(audit_script, output / "patch")
    audit_bundle(audit_script, output / "anti-cheat-scripts")
    print("KDJX runtime inputs sanitized at {}".format(output))


def sanitize_runtime(args):
    root = Path(args.runtime_root).resolve()
    if not root.is_dir():
        fail("runtime root does not exist: {}".format(root))
    # The candidate contains generated config plus inherited Python/Lua source.
    # Normalize all text artifacts before its strict runtime audit.
    clean_tree(root, allow_wildcard=True)
    print("KDJX runtime text sanitized at {}".format(root))


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--runtime-root")
    mode.add_argument("--output")
    parser.add_argument("--patch-source")
    parser.add_argument("--anti-cheat-source")
    parser.add_argument(
        "--audit-script",
        default=str(Path(__file__).with_name("audit-runtime-addresses.py")),
    )
    args = parser.parse_args()
    if args.runtime_root:
        if args.patch_source or args.anti_cheat_source:
            fail("--runtime-root cannot be combined with input source arguments")
        sanitize_runtime(args)
        return
    if not args.patch_source or not args.anti_cheat_source:
        fail("--output requires --patch-source and --anti-cheat-source")
    prepare_inputs(args)


if __name__ == "__main__":
    main()
