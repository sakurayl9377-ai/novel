#!/usr/bin/env python3
import json
import ipaddress
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import socket
import urllib.error
import urllib.parse
import urllib.request


CONFIG_PATH = Path("/etc/mihomo/config.yaml")
SECRET_PATH = Path("/etc/mihomo/controller.secret")
SUBSCRIPTION_PATH = Path("/etc/mihomo/subscription.env")
CONTROLLER_URL = "http://127.0.0.1:9090"
PROXY_URL = "http://127.0.0.1:20808"


class ControlError(RuntimeError):
    pass


def run(command, timeout=60):
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "command_failed").strip()
        raise ControlError(message[:500])
    return result.stdout.strip()


def controller_request(method, path, payload=None, timeout=10):
    secret = SECRET_PATH.read_text(encoding="utf-8").strip()
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        CONTROLLER_URL + path,
        data=data,
        method=method,
        headers={
            "Authorization": "Bearer " + secret,
            "Content-Type": "application/json",
        },
    )
    last_error = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except (urllib.error.URLError, json.JSONDecodeError) as error:
            last_error = error
            if attempt < 5:
                time.sleep(0.5)
    raise ControlError("mihomo_controller_unavailable") from last_error


def service_active():
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", "mihomo.service"],
        check=False,
    )
    return result.returncode == 0


def service_enabled():
    result = subprocess.run(
        ["systemctl", "is-enabled", "--quiet", "mihomo.service"],
        check=False,
    )
    return result.returncode == 0


def timer_status():
    active = subprocess.run(
        ["systemctl", "is-active", "--quiet", "mihomo-subscription-update.timer"],
        check=False,
    ).returncode == 0
    next_run = run(
        [
            "systemctl",
            "show",
            "mihomo-subscription-update.timer",
            "-p",
            "NextElapseUSecRealtime",
            "--value",
        ]
    )
    return {"active": active, "nextRun": next_run}


def status():
    active = service_active()
    result = {
        "service": {"active": active, "enabled": service_enabled()},
        "subscription": {
            "configured": SUBSCRIPTION_PATH.exists()
            and "SUBSCRIPTION_URL=" in SUBSCRIPTION_PATH.read_text(encoding="utf-8"),
            "timer": timer_status(),
        },
        "config": {"path": str(CONFIG_PATH), "exists": CONFIG_PATH.exists()},
        "version": "",
        "runtime": {},
        "groups": [],
    }
    if not active:
        return result

    result["version"] = str(controller_request("GET", "/version").get("version", ""))
    configs = controller_request("GET", "/configs")
    result["runtime"] = {
        "mixedPort": int(configs.get("mixed-port") or 0),
        "mode": str(configs.get("mode") or ""),
        "logLevel": str(configs.get("log-level") or ""),
        "ipv6": bool(configs.get("ipv6")),
    }
    proxies = controller_request("GET", "/proxies").get("proxies", {})
    for name, item in proxies.items():
        if item.get("type") != "Selector":
            continue
        result["groups"].append(
            {
                "name": name,
                "type": item.get("type"),
                "current": item.get("now") or "",
                "options": item.get("all") or [],
            }
        )
    return result


def normalize_subscription_url(value):
    url = str(value or "").strip()
    if (
        not url
        or len(url) > 2000
        or any(char.isspace() or ord(char) == 127 for char in url)
    ):
        raise ControlError("proxy_subscription_url_invalid")
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port or 443
    except ValueError as error:
        raise ControlError("proxy_subscription_url_invalid") from error
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or not 1 <= port <= 65535
    ):
        raise ControlError("proxy_subscription_url_invalid")
    try:
        previous_timeout = socket.getdefaulttimeout()
        socket.setdefaulttimeout(5)
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(parsed.hostname, port, type=socket.SOCK_STREAM)
        }
    except OSError as error:
        raise ControlError("proxy_subscription_host_unavailable") from error
    finally:
        socket.setdefaulttimeout(previous_timeout)
    if not addresses:
        raise ControlError("proxy_subscription_host_unavailable")
    for address in addresses:
        ip = ipaddress.ip_address(address)
        if not ip.is_global:
            raise ControlError("proxy_subscription_host_not_public")
    return urllib.parse.urlunsplit(parsed)


def set_subscription(value):
    url = normalize_subscription_url(value)
    previous = SUBSCRIPTION_PATH.read_bytes() if SUBSCRIPTION_PATH.exists() else None
    SUBSCRIPTION_PATH.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_path = tempfile.mkstemp(prefix=".subscription-", dir=SUBSCRIPTION_PATH.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            output.write("SUBSCRIPTION_URL=" + url + "\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, SUBSCRIPTION_PATH)
        try:
            run(["systemctl", "restart", "mihomo-subscription-update.service"], timeout=70)
        except Exception:
            if previous is None:
                SUBSCRIPTION_PATH.unlink(missing_ok=True)
            else:
                SUBSCRIPTION_PATH.write_bytes(previous)
                os.chmod(SUBSCRIPTION_PATH, 0o600)
            raise
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    return status()


def update_subscription():
    run(["systemctl", "restart", "mihomo-subscription-update.service"], timeout=70)
    return status()


def set_service(enabled):
    if enabled:
        run(["systemctl", "enable", "--now", "mihomo.service"])
        run(["systemctl", "enable", "--now", "mihomo-subscription-update.timer"])
    else:
        run(["systemctl", "disable", "--now", "mihomo-subscription-update.timer"])
        run(["systemctl", "disable", "--now", "mihomo.service"])
    return status()


def set_group(group, choice):
    group = str(group or "").strip()
    choice = str(choice or "").strip()
    if not group or not choice or len(group) > 200 or len(choice) > 300:
        raise ControlError("proxy_group_selection_invalid")
    proxies = controller_request("GET", "/proxies").get("proxies", {})
    item = proxies.get(group)
    if not item or item.get("type") != "Selector" or choice not in (item.get("all") or []):
        raise ControlError("proxy_group_selection_invalid")
    encoded_group = urllib.parse.quote(group, safe="")
    controller_request("PUT", "/proxies/" + encoded_group, {"name": choice})
    return status()


def test_proxy():
    handler = urllib.request.ProxyHandler({"http": PROXY_URL, "https": PROXY_URL})
    opener = urllib.request.build_opener(handler)
    results = []
    for name, url in (
        ("github", "https://api.github.com/rate_limit"),
        ("google", "https://www.google.com/generate_204"),
        ("ip", "https://api.ipify.org"),
    ):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "NovelProxyCheck/1.0"})
            with opener.open(request, timeout=12) as response:
                body = response.read(200).decode("utf-8", errors="replace").strip()
                results.append(
                    {
                        "name": name,
                        "ok": 200 <= response.status < 400,
                        "status": response.status,
                        "value": body if name == "ip" else "",
                    }
                )
        except Exception:
            results.append({"name": name, "ok": False, "status": 0, "value": ""})
    return {"ok": all(item["ok"] for item in results), "checks": results}


def main():
    request = json.load(sys.stdin)
    action = request.get("action")
    if action == "status":
        response = status()
    elif action == "set-subscription":
        response = set_subscription(request.get("url"))
    elif action == "update-subscription":
        response = update_subscription()
    elif action == "set-service":
        response = set_service(request.get("enabled") is True)
    elif action == "set-group":
        response = set_group(request.get("group"), request.get("choice"))
    elif action == "test":
        response = test_proxy()
    else:
        raise ControlError("proxy_action_invalid")
    print(json.dumps({"ok": True, "data": response}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        message = str(error or "proxy_control_failed")[:500]
        print(json.dumps({"ok": False, "error": message}, ensure_ascii=False))
        sys.exit(1)
