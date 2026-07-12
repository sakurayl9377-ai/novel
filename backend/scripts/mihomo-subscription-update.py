#!/usr/bin/env python3
import argparse
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
import sys
import tempfile
import time
import urllib.parse

try:
    import grp
    import pwd
except ImportError:  # pragma: no cover - only unavailable on non-Unix test hosts.
    grp = None
    pwd = None


LEGACY_SUBSCRIPTION_PATH = Path("/etc/mihomo/subscription.env")
SUBSCRIPTIONS_PATH = Path("/etc/mihomo/subscriptions.json")
PROVIDER_PATH = Path("/var/lib/mihomo/providers/dylian.json")
PROVIDER_USER = "mihomo"
PROVIDER_GROUP = "mihomo"
MAX_SUBSCRIPTIONS = 12
MAX_SUBSCRIPTION_NAME_LENGTH = 80
MAX_ENV_BYTES = 8192
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
MAX_REDIRECTS = 4
REQUEST_TIMEOUT_SECONDS = 45
SUBSCRIPTION_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class SubscriptionUpdateError(RuntimeError):
    pass


def normalize_subscription_url(value):
    url = str(value or "").strip()
    if (
        not url
        or len(url) > 2000
        or any(char.isspace() or ord(char) == 127 for char in url)
    ):
        raise SubscriptionUpdateError("proxy_subscription_url_invalid")
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port or 443
    except ValueError as error:
        raise SubscriptionUpdateError("proxy_subscription_url_invalid") from error
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or not 1 <= port <= 65535
    ):
        raise SubscriptionUpdateError("proxy_subscription_url_invalid")
    return urllib.parse.urlunsplit(parsed)


def normalize_subscription_name(value):
    name = str(value or "").strip()
    if (
        not name
        or len(name) > MAX_SUBSCRIPTION_NAME_LENGTH
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
    ):
        raise SubscriptionUpdateError("proxy_subscription_name_invalid")
    return name


def normalize_subscription_record(value):
    if not isinstance(value, dict):
        raise SubscriptionUpdateError("proxy_subscription_store_invalid")
    identifier = str(value.get("id") or "").strip()
    if not SUBSCRIPTION_ID_PATTERN.fullmatch(identifier):
        raise SubscriptionUpdateError("proxy_subscription_store_invalid")
    return {
        "id": identifier,
        "name": normalize_subscription_name(value.get("name")),
        "url": normalize_subscription_url(value.get("url")),
    }


def read_legacy_subscription(path=LEGACY_SUBSCRIPTION_PATH):
    try:
        with path.open("rb") as source:
            raw = source.read(MAX_ENV_BYTES + 1)
    except OSError as error:
        raise SubscriptionUpdateError("proxy_subscription_env_invalid") from error
    if len(raw) > MAX_ENV_BYTES:
        raise SubscriptionUpdateError("proxy_subscription_env_invalid")
    try:
        lines = raw.decode("utf-8-sig").splitlines()
    except UnicodeDecodeError as error:
        raise SubscriptionUpdateError("proxy_subscription_env_invalid") from error
    values = [
        line.split("=", 1)[1]
        for line in lines
        if line.startswith("SUBSCRIPTION_URL=")
    ]
    if len(values) != 1:
        raise SubscriptionUpdateError("proxy_subscription_env_invalid")
    return {"id": "legacy", "name": "默认订阅", "url": normalize_subscription_url(values[0])}


def read_subscriptions(
    path=SUBSCRIPTIONS_PATH,
    legacy_path=LEGACY_SUBSCRIPTION_PATH,
):
    if not path.exists():
        return [read_legacy_subscription(legacy_path)] if legacy_path.exists() else []
    try:
        raw = path.read_bytes()
        data = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SubscriptionUpdateError("proxy_subscription_store_invalid") from error
    subscriptions = data.get("subscriptions") if isinstance(data, dict) else None
    if not isinstance(subscriptions, list) or len(subscriptions) > MAX_SUBSCRIPTIONS:
        raise SubscriptionUpdateError("proxy_subscription_store_invalid")
    result = [normalize_subscription_record(item) for item in subscriptions]
    if len({item["id"] for item in result}) != len(result):
        raise SubscriptionUpdateError("proxy_subscription_store_invalid")
    return result


def resolve_public_addresses(hostname, port, resolver=socket.getaddrinfo):
    try:
        records = resolver(
            hostname,
            port,
            type=socket.SOCK_STREAM,
            proto=socket.IPPROTO_TCP,
        )
    except OSError as error:
        raise SubscriptionUpdateError("proxy_subscription_host_unavailable") from error

    addresses = []
    for record in records:
        address = record[4][0]
        try:
            ip = ipaddress.ip_address(address.split("%", 1)[0])
        except ValueError as error:
            raise SubscriptionUpdateError("proxy_subscription_host_unavailable") from error
        if not ip.is_global:
            raise SubscriptionUpdateError("proxy_subscription_host_not_public")
        if address not in addresses:
            addresses.append(address)
    if not addresses:
        raise SubscriptionUpdateError("proxy_subscription_host_unavailable")
    return addresses


def pinned_https_connection(hostname, port, address, timeout, context):
    connection = http.client.HTTPSConnection(
        hostname,
        port=port,
        timeout=timeout,
        context=context,
    )

    def create_connection(_target, inner_timeout=None, source_address=None):
        return socket.create_connection(
            (address, port),
            timeout=inner_timeout,
            source_address=source_address,
        )

    # TLS validation still targets the hostname while the socket is pinned to
    # the public address checked above.
    connection._create_connection = create_connection
    return connection


def fetch_subscription(
    initial_url,
    *,
    resolver=socket.getaddrinfo,
    connection_factory=pinned_https_connection,
    max_bytes=MAX_RESPONSE_BYTES,
    max_redirects=MAX_REDIRECTS,
    timeout_seconds=REQUEST_TIMEOUT_SECONDS,
    ssl_context=None,
):
    current_url = normalize_subscription_url(initial_url)
    context = ssl_context or ssl.create_default_context()
    deadline = time.monotonic() + timeout_seconds

    for redirect_count in range(max_redirects + 1):
        parsed = urllib.parse.urlsplit(current_url)
        port = parsed.port or 443
        addresses = resolve_public_addresses(parsed.hostname, port, resolver)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SubscriptionUpdateError("proxy_subscription_download_timeout")

        response = None
        connection = None
        for address in addresses:
            try:
                connection = connection_factory(parsed.hostname, port, address, remaining, context)
                target = urllib.parse.urlunsplit(("", "", parsed.path or "/", parsed.query, ""))
                connection.request(
                    "GET",
                    target,
                    headers={
                        "Accept": "application/json",
                        "User-Agent": "NovelMihomoSubscription/1.0",
                    },
                )
                response = connection.getresponse()
                break
            except (OSError, ssl.SSLError, http.client.HTTPException):
                if connection is not None:
                    connection.close()
                connection = None

        if response is None or connection is None:
            raise SubscriptionUpdateError("proxy_subscription_download_failed")

        try:
            if response.status in (301, 302, 303, 307, 308):
                location = response.getheader("Location")
                if not location or redirect_count >= max_redirects:
                    raise SubscriptionUpdateError("proxy_subscription_redirect_invalid")
                redirected = urllib.parse.urljoin(current_url, location)
                try:
                    current_url = normalize_subscription_url(redirected)
                except SubscriptionUpdateError as error:
                    raise SubscriptionUpdateError("proxy_subscription_redirect_invalid") from error
                continue

            if response.status != 200:
                raise SubscriptionUpdateError("proxy_subscription_http_error")
            content_length = response.getheader("Content-Length")
            if content_length:
                try:
                    declared_size = int(content_length)
                except ValueError as error:
                    raise SubscriptionUpdateError("proxy_subscription_response_invalid") from error
                if declared_size < 0 or declared_size > max_bytes:
                    raise SubscriptionUpdateError("proxy_subscription_response_too_large")
            try:
                body = response.read(max_bytes + 1)
            except (OSError, ssl.SSLError, http.client.HTTPException) as error:
                raise SubscriptionUpdateError("proxy_subscription_download_failed") from error
            if len(body) > max_bytes:
                raise SubscriptionUpdateError("proxy_subscription_response_too_large")
            return body
        finally:
            connection.close()

    raise SubscriptionUpdateError("proxy_subscription_redirect_invalid")


def normalize_provider_proxies(raw, source_name):
    try:
        text = raw.decode("utf-8-sig")
        data, _ = json.JSONDecoder().raw_decode(text.lstrip())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SubscriptionUpdateError("proxy_subscription_response_invalid") from error
    proxies = data.get("proxies") if isinstance(data, dict) else None
    if not isinstance(proxies, list) or not proxies:
        raise SubscriptionUpdateError("proxy_subscription_proxies_missing")

    prefix = normalize_subscription_name(source_name)
    normalized = []
    for proxy in proxies:
        if not isinstance(proxy, dict):
            continue
        node = dict(proxy)
        original_name = str(node.get("name") or "").strip()
        if not original_name or any(ord(char) < 32 or ord(char) == 127 for char in original_name):
            continue
        node["name"] = f"[{prefix}] {original_name}"[:300]
        normalized.append(node)
    if not normalized:
        raise SubscriptionUpdateError("proxy_subscription_proxies_missing")
    return normalized


def build_provider_payload(subscription_payloads):
    merged = []
    names = set()
    for subscription, raw in subscription_payloads:
        for proxy in normalize_provider_proxies(raw, subscription["name"]):
            base_name = proxy["name"]
            name = base_name
            suffix = 2
            while name in names:
                name = f"{base_name[:286]} #{suffix}"
                suffix += 1
            proxy["name"] = name
            names.add(name)
            merged.append(proxy)
    return json.dumps({"proxies": merged}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def atomic_write_provider(payload, path=PROVIDER_PATH, user=PROVIDER_USER, group=PROVIDER_GROUP):
    if pwd is None or grp is None:
        raise SubscriptionUpdateError("proxy_subscription_write_failed")
    try:
        uid = pwd.getpwnam(user).pw_uid
        gid = grp.getgrnam(group).gr_gid
        path.parent.mkdir(parents=True, exist_ok=True)
        handle, temp_path = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(handle, "wb") as output:
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
                os.fchmod(output.fileno(), 0o600)
                os.fchown(output.fileno(), uid, gid)
            os.replace(temp_path, path)
            directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
    except (KeyError, OSError) as error:
        raise SubscriptionUpdateError("proxy_subscription_write_failed") from error


def update_subscriptions(subscription_id=None):
    subscriptions = read_subscriptions()
    if subscription_id and subscription_id not in {item["id"] for item in subscriptions}:
        raise SubscriptionUpdateError("proxy_subscription_not_found")
    payloads = [(subscription, fetch_subscription(subscription["url"])) for subscription in subscriptions]
    atomic_write_provider(build_provider_payload(payloads))
    return len(subscriptions), sum(len(normalize_provider_proxies(raw, item["name"])) for item, raw in payloads)


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--subscription-id", default="")
    args = parser.parse_args()
    subscription_count, node_count = update_subscriptions(args.subscription_id or None)
    print(f"subscription_update_status=ok subscriptions={subscription_count} nodes={node_count}")


if __name__ == "__main__":
    try:
        main()
    except SubscriptionUpdateError as error:
        print(f"subscription_update_error={error}", file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("subscription_update_error=proxy_subscription_update_failed", file=sys.stderr)
        sys.exit(1)
