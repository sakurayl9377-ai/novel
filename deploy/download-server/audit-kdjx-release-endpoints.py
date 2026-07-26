#!/usr/bin/env python3
"""Reject KDJX publish artifacts that retain a non-owned endpoint."""

from __future__ import print_function

import argparse
import ipaddress
import re
import sys
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlparse


OWNED_GAME_HOST = "49.232.137.85"
OWNED_DOWNLOAD_HOST = "novel.kxhub.xyz"
FORBIDDEN_LITERALS = (
    "192.168.",
    "202.189.12.86",
    "107.151.203.236",
    "123.207.108.22",
    "172.81.227.66",
    "212.64.40.75",
    "123.com",
    "oss.kuyangsh.cn",
    "tiancigame.cn",
    "qingshangame.com",
    "adt.cpatrk.net",
    "me.cpatrk.net",
    "cloud.xdrig.com",
    "i.tddmp.com",
    "talkingdata.net",
    "bugly.qq.com",
    "rqd.uu.qq.com",
    "qm.qq.com",
    "116.196.67.142",
    "116.196.84.232",
)
METADATA_URL_LITERALS = frozenset({
    "https://android.googlesource.com/toolchain/clang",
    "https://android.googlesource.com/toolchain/llvm",
    "https://android.googlesource.com/toolchain/llvm-project",
    "https://curl.haxx.se/docs/http-cookies.html",
    "http://ns.adobe.com/bwf/bext/1.0/",
    "http://ns.adobe.com/creatorAtom/1.0/",
    "http://ns.adobe.com/ixml/1.0/",
    "http://ns.adobe.com/xap/1.0/",
    "http://ns.adobe.com/xap/1.0/mm/",
    "http://ns.adobe.com/xap/1.0/sType/Dimensions#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceEvent#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceRef#",
    "http://ns.adobe.com/xap/1.0/DynamicMedia/",
    "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
    "http://purl.org/dc/elements/1.1/",
    "http://schemas.android.com/apk/res/android",
    "http://schemas.android.com/apk/res-auto",
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd",
    "https://www.openssl.org/docs/faq.html",
    "http://www.videolan.org/x264.html",
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
})
NATIVE_LIBRARY_METADATA_URLS = frozenset({
    "https://android.googlesource.com/toolchain/clang",
    "https://android.googlesource.com/toolchain/llvm",
    "https://android.googlesource.com/toolchain/llvm-project",
    "https://curl.haxx.se/docs/http-cookies.html",
    "https://www.openssl.org/docs/faq.html",
})
MP3_XMP_METADATA_URLS = frozenset({
    "http://ns.adobe.com/bwf/bext/1.0/",
    "http://ns.adobe.com/creatorAtom/1.0/",
    "http://ns.adobe.com/ixml/1.0/",
    "http://ns.adobe.com/xap/1.0/",
    "http://ns.adobe.com/xap/1.0/mm/",
    "http://ns.adobe.com/xap/1.0/sType/Dimensions#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceEvent#",
    "http://ns.adobe.com/xap/1.0/sType/ResourceRef#",
    "http://ns.adobe.com/xap/1.0/DynamicMedia/",
    "http://ns.adobe.com/xmp/1.0/DynamicMedia/",
    "http://purl.org/dc/elements/1.1/",
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
})
KNOWN_NON_ENDPOINT_IP_LITERALS = frozenset({"0.0.0.0", "127.0.0.255", "2.1.0.0"})
NATIVE_LIBRARY_METADATA_IP_LITERALS = frozenset({"1.0.0.0", "1.2.0.4", "127.0.0.1"})
URL_RE = re.compile(r"https?://[^\s\"'<>\\]+", re.IGNORECASE)
IP_RE = re.compile(r"(?<![A-Za-z0-9_.-])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_.-])")
HOSTNAME_RE = re.compile(
    r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"
)


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def clean_url(value):
    return value.split("\x00", 1)[0].rstrip(".,;:)]}")


def is_apk_native_library(entry_name):
    return entry_name.startswith("lib/") and entry_name.endswith("/libcocos2dlua.so")


def is_valid_endpoint_host(host):
    if not host:
        return False
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return bool(HOSTNAME_RE.fullmatch(host))


def allowed_metadata_url(value, entry_name, artifact_kind):
    if artifact_kind != "apk":
        return False
    value = clean_url(value)
    if value not in METADATA_URL_LITERALS:
        return False
    entry = entry_name.replace("\\", "/")
    if value.startswith("http://schemas.android.com/"):
        return entry == "classes.dex" or (entry.startswith("res/") and entry.endswith(".xml"))
    if value in NATIVE_LIBRARY_METADATA_URLS:
        return is_apk_native_library(entry)
    if value in MP3_XMP_METADATA_URLS:
        return entry.startswith("assets/") and entry.endswith(".mp3")
    if value == "http://www.apple.com/DTDs/PropertyList-1.0.dtd":
        return (entry.startswith("assets/") and entry.endswith(".plist")) or is_apk_native_library(entry)
    return value == "http://www.videolan.org/x264.html" and entry.startswith("assets/") and entry.endswith(".mp4")


def allowed_url(value, entry_name, artifact_kind):
    literal = clean_url(value)
    try:
        parsed = urlparse(literal)
        host = (parsed.hostname or "").lower()
        port = parsed.port
    except ValueError:
        return False
    # Format strings such as ``http://%s`` are not concrete network targets.
    # A concrete hostname or IP still has to satisfy the owned policy below.
    if not is_valid_endpoint_host(host):
        return True
    if (
        host == OWNED_GAME_HOST
        and parsed.scheme == "https"
        and port in (None, 443)
        and not parsed.username
        and not parsed.password
    ):
        return True
    if (
        host == OWNED_DOWNLOAD_HOST
        and parsed.scheme == "https"
        and port in (None, 443)
        and not parsed.username
        and not parsed.password
        and parsed.path.startswith("/games/kdjx/")
    ):
        return True
    return allowed_metadata_url(literal, entry_name, artifact_kind)


def allowed_ip(value, entry_name, artifact_kind):
    try:
        address = str(ipaddress.ip_address(value))
    except ValueError:
        return True
    if address == OWNED_GAME_HOST or address in KNOWN_NON_ENDPOINT_IP_LITERALS:
        return True
    return (
        artifact_kind == "apk"
        and is_apk_native_library(entry_name.replace("\\", "/"))
        and address in NATIVE_LIBRARY_METADATA_IP_LITERALS
    )


def scan_text(data, entry_name, artifact_kind, findings):
    normalized = data
    if "%" in normalized or r"\\/" in normalized:
        normalized = unquote(normalized.replace(r"\\/", "/"))
    lowered = normalized.lower()
    for literal in FORBIDDEN_LITERALS:
        if literal in lowered:
            findings.add((entry_name, "legacy", literal))
    for literal in URL_RE.findall(normalized):
        if not allowed_url(literal, entry_name, artifact_kind):
            findings.add((entry_name, "url", clean_url(literal)))
    for literal in IP_RE.findall(normalized):
        if not allowed_ip(literal, entry_name, artifact_kind):
            findings.add((entry_name, "ip", literal))


def scan_stream(source, entry_name, artifact_kind, findings):
    tail = ""
    while True:
        block = source.read(1024 * 1024)
        if not block:
            break
        data = tail + block.decode("latin-1")
        scan_text(data, entry_name, artifact_kind, findings)
        tail = data[-8192:]


def scan_hot_staging(root):
    if not root.is_dir() or root.is_symlink():
        fail("hot_staging_invalid")
    root = root.resolve(strict=True)
    findings = set()
    count = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        count += 1
        with path.open("rb") as source:
            scan_stream(source, path.relative_to(root).as_posix(), "hot", findings)
    if not count:
        fail("hot_staging_empty")
    return findings, count


def scan_apk(path):
    if not path.is_file() or path.is_symlink():
        fail("apk_invalid")
    findings = set()
    try:
        with zipfile.ZipFile(str(path), "r") as archive:
            entries = [entry for entry in archive.infolist() if not entry.is_dir()]
            if not entries:
                fail("apk_empty")
            for entry in entries:
                with archive.open(entry, "r") as source:
                    scan_stream(source, entry.filename, "apk", findings)
    except (OSError, zipfile.BadZipFile) as exc:
        fail("apk_unreadable: {}".format(exc))
    return findings, len(entries)


def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--hot-staging")
    mode.add_argument("--apk")
    args = parser.parse_args()
    if args.hot_staging:
        findings, count = scan_hot_staging(Path(args.hot_staging))
        artifact_kind = "hot_staging"
    else:
        findings, count = scan_apk(Path(args.apk))
        artifact_kind = "apk"
    if findings:
        for entry_name, kind, value in sorted(findings):
            print("{}: {} {} is not allowed".format(entry_name, kind, value), file=sys.stderr)
        raise SystemExit(1)
    print("KDJX {} endpoint audit passed ({} entries).".format(artifact_kind, count))


if __name__ == "__main__":
    main()
