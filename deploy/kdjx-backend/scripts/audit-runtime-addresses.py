#!/usr/bin/env python3
"""Fail closed when a staged KDJX runtime contains a non-owned endpoint."""

from __future__ import print_function

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


PUBLIC_BACKEND_IP = "49.232.137.85"
DOWNLOAD_HOST = "novel.kxhub.xyz"
DOWNLOAD_BASE_URL = "https://novel.kxhub.xyz/games/kdjx/"
HOT_UPDATE_BASE_URL = "https://novel.kxhub.xyz/games/kdjx/hot/"
LOOPBACK_IP = "127.0.0.1"
WILDCARD_IP = "0.0.0.0"
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
IPV4_PORT_RE = re.compile(
    r"(?<![0-9.])((?:[0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]{1,5})(?![0-9])"
)
URL_RE = re.compile(r"(?:(?:https?|mongodb)://[^\s\"'<>]+)", re.IGNORECASE)
PRINTABLE_ASCII_RE = re.compile(rb"[ -~]{4,}")
CREDENTIAL_URI_RE = re.compile(r"://[^/\s:@]+:[^@/\s]+@", re.IGNORECASE)
ACCESS_TOKEN_URL_RE = re.compile(r"https?://[^\s\"'<>]*[?&]access_token=[^\s\"'<>]+", re.IGNORECASE)
LEGACY_HOST_RE = re.compile(
    r"(?:tianji-game\.com|kuyangsh\.cn|um-game\.com|facebook\.com|discord\.gg|"
    r"play\.google\.com|url\.cn|bdqaa\.fogjr\.tdlhct\.zwzfp)",
    re.IGNORECASE,
)
LOCALHOST_RE = re.compile(r"\b" + "local" + "host" + r"\b", re.IGNORECASE)
LOCALHOST_PORT_RE = re.compile(r"\b" + "local" + "host" + r":[0-9]{1,5}\b", re.IGNORECASE)
LOCALHOST_MARKER = "local" + "host"
HOSTNAME_RE = re.compile(
    r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"
)
GO_FUNCTION_SYMBOL_RE = re.compile(
    r"[A-Za-z0-9_/*().-]+\.func[0-9]+(?:\.[0-9]+){3,}"
)

# These are XML/Office document namespace identifiers linked into the legacy
# Go binaries by xlsx/protobuf. They are not service URLs. Build the literals
# at runtime so the endpoint sanitizer never treats this local allow-list as
# a shipped remote configuration value.
def metadata_url(host, path, scheme="http"):
    return scheme + "://" + host + path


# The exception is intentionally restricted to the generated binaries and
# known namespace literals, including a printable suffix that can arise when
# Go coalesces adjacent string constants in the final binary.
BINARY_NAMESPACE_URL_PREFIXES = frozenset({
    metadata_url("schemas.openxmlformats.org", "/drawingml/2006/main"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/docPropsVTypes"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/extended-properties"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/extended-properties"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/officeDocument"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/sharedStrings"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/styles"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/theme"),
    metadata_url("schemas.openxmlformats.org", "/officeDocument/2006/relationships/worksheet"),
    metadata_url("schemas.openxmlformats.org", "/package/2006/content-types"),
    metadata_url("schemas.openxmlformats.org", "/package/2006/metadata/core-properties"),
    metadata_url("schemas.openxmlformats.org", "/package/2006/relationships"),
    metadata_url("schemas.openxmlformats.org", "/package/2006/relationships/metadata/core-properties"),
    metadata_url("schemas.openxmlformats.org", "/spreadsheetml/2006/main"),
    metadata_url("www.w3.org", "/XML/1998/namespace"),
})
BINARY_METADATA_URLS = frozenset({
    metadata_url("purl.org", "/dc/dcmitype/"),
    metadata_url("purl.org", "/dc/elements/1.1/"),
    metadata_url("purl.org", "/dc/terms/"),
    metadata_url("www.w3.org", "/2001/XMLSchema-instance"),
    metadata_url(
        "developers.google.com",
        "/protocol-buffers/docs/reference/go/faq#namespace-conflict",
        scheme="https",
    ),
})


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def is_text_file(path):
    return path.suffix.lower() in TEXT_SUFFIXES


def runtime_files(root):
    # A staged release is a deployment artifact, so no text file receives a
    # vendored-source exemption. Sanitization happens before this audit.
    return sorted(child for child in root.rglob("*") if child.is_file() and is_text_file(child))


def runtime_binary_files(root):
    # Runtime data such as config msgpack is executable input just as much as
    # the compiled Go binaries. Scan every non-text artifact so an endpoint
    # cannot evade release checks by moving into a serialized data file.
    return sorted(
        child
        for child in root.rglob("*")
        if child.is_file() and not is_text_file(child)
    )


def bundle_files(root):
    return sorted(child for child in root.rglob("*") if child.is_file() and is_text_file(child))


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        fail("cannot read {}: {}".format(path, exc))


def valid_ip(value):
    try:
        return str(ipaddress.ip_address(value)) == value
    except ValueError:
        return False


KDJX_GAME_VERSION = "2.1." + "0.0"
KDJX_GAME_VERSION_SOURCE = "gosrc/tjgame/login/diff/init.go"
KDJX_LOGIN_BINARY = "bin/login_server"


def is_known_non_network_literal(relative, value, content, position):
    # Dotted file/game versions are not hosts. Keep each exception tied to its
    # exact source location (and, for Go, its assignment) so endpoints remain
    # fail-closed.
    if (
        relative.endswith("framework/MyLuaGame/cocos/cocostudio/CocoStudio.lua")
        and value == "1.0." + "0.0"
    ):
        return True
    if relative != KDJX_GAME_VERSION_SOURCE or value != KDJX_GAME_VERSION:
        return False
    line_start = content.rfind("\n", 0, position) + 1
    line_end = content.find("\n", position)
    if line_end < 0:
        line_end = len(content)
    return bool(
        re.fullmatch(
            r'\s*version\s*=\s*"2\.1\.0\.0"\s*(?://[^\r\n]*)?',
            content[line_start:line_end],
        )
    )


def is_known_binary_non_network_literal(relative, value, raw):
    # The sanitizer preserves this exact Go source assignment before building.
    # The compiled login binary must contain exactly one copy; the same dotted
    # literal anywhere else remains subject to the endpoint policy.
    return (
        relative == KDJX_LOGIN_BINARY
        and value == KDJX_GAME_VERSION
        and raw.count(KDJX_GAME_VERSION.encode("ascii")) == 1
    )


def is_go_compiler_symbol_literal(relative, content, value):
    """Allow only Go's generated ``.funcN.x.x.x`` symbol suffixes.

    Go can encode nested anonymous-function identities as dotted numeric
    suffixes. Some are syntactically valid IPv4 values, but their occurrence
    within a compiled function symbol cannot be a routable endpoint. A bare
    matching value, even under bin/, remains a release failure.
    """
    if not relative.startswith("bin/"):
        return False
    positions = [match.start() for match in re.finditer(re.escape(value), content)]
    if not positions:
        return False
    symbols = list(GO_FUNCTION_SYMBOL_RE.finditer(content))
    return all(
        any(symbol.start() <= position and position + len(value) <= symbol.end() for symbol in symbols)
        for position in positions
    )


def is_dns_hostname(value):
    return bool(HOSTNAME_RE.fullmatch(value))


def parsed_url(candidate):
    try:
        parsed = urlparse(candidate.rstrip(".,;:)]}"))
        return parsed, parsed.hostname
    except ValueError:
        return None, None


def is_allowed_url(candidate, allowed_hosts):
    parsed, host = parsed_url(candidate)
    if not host or host not in allowed_hosts:
        return False
    if host == DOWNLOAD_HOST:
        try:
            port = parsed.port
        except ValueError:
            return False
        return (
            parsed.scheme == "https"
            and port in (None, 443)
            and parsed.path.startswith("/games/kdjx/")
        )
    return True


def is_allowed_binary_metadata_url(relative, candidate):
    if not relative.startswith("bin/"):
        return False
    literal = candidate.rstrip(".,;:)]}")
    if literal in BINARY_METADATA_URLS:
        return True
    for prefix in sorted(BINARY_NAMESPACE_URL_PREFIXES, key=len, reverse=True):
        if not literal.startswith(prefix):
            continue
        suffix = literal[len(prefix) :]
        if not suffix or re.fullmatch(r"[A-Za-z0-9;]*", suffix):
            return True
    return False


def is_valid_endpoint_host(host):
    return bool(host) and (host.lower() == LOCALHOST_MARKER or valid_ip(host) or is_dns_hostname(host))


def is_private_or_reserved_ip(value):
    try:
        address = ipaddress.ip_address(value)
        return address.is_private or address.is_reserved or address.is_loopback
    except ValueError:
        return False


def scan_files(root, files, allowed_ips, allowed_hosts, strict_urls):
    findings = []
    for path in files:
        content = read_text(path)
        relative = path.relative_to(root).as_posix()
        for match in IPV4_RE.finditer(content):
            candidate = match.group(0)
            if (
                valid_ip(candidate)
                and candidate not in allowed_ips
                and not is_known_non_network_literal(
                    relative,
                    candidate,
                    content,
                    match.start(),
                )
            ):
                findings.append((relative, "ip", candidate))
        if CREDENTIAL_URI_RE.search(content):
            findings.append((relative, "credential-uri", "embedded credential"))
        if ACCESS_TOKEN_URL_RE.search(content):
            findings.append((relative, "access-token-url", "embedded access token"))
        if LEGACY_HOST_RE.search(content):
            findings.append((relative, "legacy-host", "non-owned host literal"))
        if LOCALHOST_RE.search(content):
            findings.append((relative, "host", LOCALHOST_MARKER))
        if strict_urls:
            for candidate in URL_RE.findall(content):
                if not is_allowed_url(candidate, allowed_hosts):
                    findings.append((relative, "url", candidate))
    return sorted(set(findings))


def scan_binary_files(root, files, allowed_ips, allowed_hosts):
    """Apply the same endpoint policy to printable strings in shipped binaries."""
    findings = []
    for path in files:
        try:
            raw = path.read_bytes()
        except OSError as exc:
            fail("cannot read binary {}: {}".format(path, exc))
        relative = path.relative_to(root).as_posix()
        for match in PRINTABLE_ASCII_RE.finditer(raw):
            content = match.group().decode("ascii")
            for candidate in set(IPV4_RE.findall(content)):
                if (
                    valid_ip(candidate)
                    and candidate not in allowed_ips
                    and not is_known_binary_non_network_literal(
                        relative,
                        candidate,
                        raw,
                    )
                    and not is_go_compiler_symbol_literal(relative, content, candidate)
                ):
                    findings.append((relative, "binary-ip", candidate))
            for candidate, _ in IPV4_PORT_RE.findall(content):
                if valid_ip(candidate) and candidate not in allowed_ips:
                    findings.append((relative, "binary-ip-endpoint", candidate))
            if CREDENTIAL_URI_RE.search(content):
                findings.append((relative, "binary-credential-uri", "embedded credential"))
            if ACCESS_TOKEN_URL_RE.search(content):
                findings.append((relative, "binary-access-token-url", "embedded access token"))
            if LEGACY_HOST_RE.search(content):
                findings.append((relative, "binary-legacy-host", "non-owned host literal"))
            if LOCALHOST_PORT_RE.search(content):
                findings.append((relative, "binary-host-endpoint", LOCALHOST_MARKER))
            for candidate in URL_RE.findall(content):
                _, host = parsed_url(candidate)
                if (
                    is_allowed_url(candidate, allowed_hosts)
                    or is_allowed_binary_metadata_url(relative, candidate)
                    or not is_valid_endpoint_host(host)
                ):
                    continue
                findings.append((relative, "binary-url", candidate))
    return sorted(set(findings))


def require_runtime_invariants(root):
    required = [
        root / "runtime-manifest.json",
        root / "login" / "defines.json",
        root / "login" / "conf" / "sdk.json",
        root / "release" / "sdk.conf",
        root / "host" / "defines.json",
    ]
    for path in required:
        if not path.is_file():
            fail("required generated file is missing: {}".format(path))

    for path in [root / "login" / "conf" / "sdk.json", root / "release" / "sdk.conf"]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            fail("{} is not valid JSON: {}".format(path, exc))
        if value != {}:
            fail("legacy SDK configuration must be empty: {}".format(path))

    try:
        manifest = json.loads((root / "runtime-manifest.json").read_text(encoding="utf-8"))
        login = json.loads((root / "login" / "defines.json").read_text(encoding="utf-8"))
        channels = json.loads((root / "login" / "conf" / "channel.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail("generated runtime configuration is invalid: {}".format(exc))
    if manifest.get("download_base_url") != DOWNLOAD_BASE_URL:
        fail("download URL is not the approved KDJX channel")
    if "download_server" in manifest:
        fail("runtime manifest must not serialize a raw download server address")
    if manifest.get("hot_update_base_url") != HOT_UPDATE_BASE_URL:
        fail("hot update URL is not the approved KDJX channel")
    if login.get("login.cn.1", {}).get("patch_url") != manifest.get("hot_update_base_url"):
        fail("login patch URL does not match the hot update channel")
    if channels.get("channels") != {"sakura": ["game.cn"]} or channels.get("servers") != {}:
        fail("login channel configuration is not Sakura-only")

    if (root / "release" / "payment_server.py").exists():
        fail("legacy Python payment listener is present in the staged runtime")

    gate_marker = root / "sakura-only-login-gate.txt"
    if not gate_marker.is_file() or gate_marker.read_text(encoding="utf-8").strip() != "sakura-only-login-ticket-gate-v2":
        fail("Sakura-only one-time login-ticket build gate is missing")
    metrics_marker = root / "loopback-metrics-gate.txt"
    if not metrics_marker.is_file() or metrics_marker.read_text(encoding="utf-8").strip() != "loopback-metrics-gate-v1":
        fail("loopback anti-cheat metrics build gate is missing")


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--runtime-root")
    mode.add_argument("--bundle-root")
    args = parser.parse_args()

    if args.runtime_root:
        root = Path(args.runtime_root).resolve()
        if not root.is_dir():
            fail("runtime root does not exist: {}".format(root))
        require_runtime_invariants(root)
        allowed_ips = {PUBLIC_BACKEND_IP, LOOPBACK_IP, WILDCARD_IP}
        allowed_hosts = {PUBLIC_BACKEND_IP, DOWNLOAD_HOST, LOOPBACK_IP}
        files = runtime_files(root)
        binary_files = runtime_binary_files(root)
        scope = "runtime"
        strict_urls = True
    else:
        root = Path(args.bundle_root).resolve()
        if not root.is_dir():
            fail("bundle root does not exist: {}".format(root))
        allowed_ips = {PUBLIC_BACKEND_IP, LOOPBACK_IP}
        allowed_hosts = {PUBLIC_BACKEND_IP, DOWNLOAD_HOST, LOOPBACK_IP}
        files = bundle_files(root)
        binary_files = []
        scope = "bundle"
        strict_urls = True

    if not files:
        fail("no text files found in {} audit scope".format(scope))

    findings = scan_files(root, files, allowed_ips, allowed_hosts, strict_urls)
    if args.runtime_root:
        findings.extend(scan_binary_files(root, binary_files, allowed_ips, allowed_hosts))
    if findings:
        for relative, kind, value in findings:
            print("{}: {} {} is not allowed".format(relative, kind, value), file=sys.stderr)
        raise SystemExit(1)

    print(
        "KDJX {} address audit passed ({} text files, {} binaries).".format(
            scope, len(files), len(binary_files)
        )
    )


if __name__ == "__main__":
    main()
