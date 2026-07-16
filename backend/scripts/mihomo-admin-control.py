#!/usr/bin/env python3
import json
import ipaddress
import os
from pathlib import Path
import re
import shutil
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
LEGACY_SUBSCRIPTION_PATH = Path("/etc/mihomo/subscription.env")
SUBSCRIPTIONS_PATH = Path("/etc/mihomo/subscriptions.json")
PROVIDER_PATH = Path("/var/lib/mihomo/providers/dylian.json")
CONTROLLER_URL = "http://127.0.0.1:9090"
PROXY_URL = "http://127.0.0.1:20808"
UPDATER_PATH = "/usr/local/libexec/mihomo-update-subscription"
MAX_SUBSCRIPTIONS = 12
MAX_SUBSCRIPTION_NAME_LENGTH = 80
SUBSCRIPTION_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
MANUAL_GROUP = "NODE-MANUAL"
MODE_GROUP = "PROXY-MODE"
PROVIDER_NAME = "dylian"


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


def controller_request(method, path, payload=None, timeout=10, attempts=6):
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
    safe_attempts = max(1, min(6, int(attempts or 1)))
    for attempt in range(safe_attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last_error = error
            if attempt < safe_attempts - 1:
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


def proxy_nodes(proxies, provider_entries=None):
    entries = provider_entries
    if entries is None:
        try:
            provider = json.loads(PROVIDER_PATH.read_text(encoding="utf-8"))
            entries = provider.get("proxies") if isinstance(provider, dict) else None
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            entries = []
    if not isinstance(entries, list):
        entries = []
    nodes = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "").strip()
        if not name or len(name) > 300:
            continue
        runtime = proxies.get(name) if isinstance(proxies, dict) else {}
        history = entry.get("history") or []
        if not history and isinstance(runtime, dict):
            history = runtime.get("history") or []
        latest = history[-1] if isinstance(history, list) and history else {}
        delay = latest.get("delay") if isinstance(latest, dict) else 0
        alive = entry.get("alive")
        if not isinstance(alive, bool):
            alive = bool(runtime.get("alive")) if isinstance(runtime, dict) else False
        nodes.append(
            {
                "name": name,
                "type": str(entry.get("type") or "代理")[:80],
                "alive": alive,
                "delay": int(delay) if isinstance(delay, int) and delay >= 0 else 0,
            }
        )
    return sorted(nodes, key=lambda item: item["name"].casefold())


def status():
    active = service_active()
    subscriptions = read_subscriptions()
    result = {
        "service": {"active": active, "enabled": service_enabled()},
        "subscription": {"configured": bool(subscriptions), "timer": timer_status()},
        "subscriptions": [],
        "config": {"path": str(CONFIG_PATH), "exists": CONFIG_PATH.exists()},
        "version": "",
        "runtime": {},
        "groups": [],
        "nodes": [],
        "nodeTotal": 0,
        "manualModeEnabled": False,
    }
    if not active:
        result["subscriptions"] = public_subscriptions(subscriptions, [])
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
    try:
        provider_entries = controller_request(
            "GET", f"/providers/proxies/{PROVIDER_NAME}"
        ).get("proxies", [])
    except ControlError:
        provider_entries = None
    nodes = proxy_nodes(proxies, provider_entries)
    result["nodes"] = nodes
    result["nodeTotal"] = len(nodes)
    result["subscriptions"] = public_subscriptions(subscriptions, nodes)
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
    result["manualModeEnabled"] = any(group["name"] == MANUAL_GROUP for group in result["groups"])
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


def normalize_subscription_name(value):
    name = str(value or "").strip()
    if (
        not name
        or len(name) > MAX_SUBSCRIPTION_NAME_LENGTH
        or any(ord(char) < 32 or ord(char) == 127 for char in name)
    ):
        raise ControlError("proxy_subscription_name_invalid")
    return name


def normalize_subscription_id(value):
    identifier = str(value or "").strip()
    if not SUBSCRIPTION_ID_PATTERN.fullmatch(identifier):
        raise ControlError("proxy_subscription_id_invalid")
    return identifier


def read_legacy_subscription():
    try:
        lines = LEGACY_SUBSCRIPTION_PATH.read_text(encoding="utf-8-sig").splitlines()
    except OSError as error:
        raise ControlError("proxy_subscription_store_invalid") from error
    values = [line.split("=", 1)[1] for line in lines if line.startswith("SUBSCRIPTION_URL=")]
    if len(values) != 1:
        raise ControlError("proxy_subscription_store_invalid")
    return {"id": "legacy", "name": "默认订阅", "url": normalize_subscription_url(values[0])}


def read_subscriptions():
    if not SUBSCRIPTIONS_PATH.exists():
        return [read_legacy_subscription()] if LEGACY_SUBSCRIPTION_PATH.exists() else []
    try:
        payload = json.loads(SUBSCRIPTIONS_PATH.read_text(encoding="utf-8"))
        entries = payload.get("subscriptions") if isinstance(payload, dict) else None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ControlError("proxy_subscription_store_invalid") from error
    if not isinstance(entries, list) or len(entries) > MAX_SUBSCRIPTIONS:
        raise ControlError("proxy_subscription_store_invalid")
    result = []
    for item in entries:
        if not isinstance(item, dict):
            raise ControlError("proxy_subscription_store_invalid")
        result.append(
            {
                "id": normalize_subscription_id(item.get("id")),
                "name": normalize_subscription_name(item.get("name")),
                "url": normalize_subscription_url(item.get("url")),
            }
        )
    if len({item["id"] for item in result}) != len(result):
        raise ControlError("proxy_subscription_store_invalid")
    return result


def write_subscriptions(subscriptions):
    if len(subscriptions) > MAX_SUBSCRIPTIONS:
        raise ControlError("proxy_subscription_limit_reached")
    SUBSCRIPTIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    handle, temp_path = tempfile.mkstemp(prefix=".subscriptions-", dir=SUBSCRIPTIONS_PATH.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            json.dump({"version": 1, "subscriptions": subscriptions}, output, ensure_ascii=False, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, SUBSCRIPTIONS_PATH)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def public_subscriptions(subscriptions, nodes):
    counts = {item["id"]: 0 for item in subscriptions}
    for node in nodes:
        for item in subscriptions:
            if node["name"].startswith(f"[{item['name']}] "):
                counts[item["id"]] += 1
                break
    return [{"id": item["id"], "name": item["name"], "nodeCount": counts[item["id"]]} for item in subscriptions]


def update_subscriptions(subscription_id=""):
    if subscription_id:
        identifier = normalize_subscription_id(subscription_id)
        if identifier not in {item["id"] for item in read_subscriptions()}:
            raise ControlError("proxy_subscription_not_found")
    command = [UPDATER_PATH]
    if subscription_id:
        command.extend(["--subscription-id", subscription_id])
    run(command, timeout=120)
    run(["systemctl", "try-restart", "mihomo.service"], timeout=40)
    return status()


def add_subscription(name, value):
    label = normalize_subscription_name(name)
    url = normalize_subscription_url(value)
    previous = read_subscriptions()
    if len(previous) >= MAX_SUBSCRIPTIONS:
        raise ControlError("proxy_subscription_limit_reached")
    identifier = f"sub-{int(time.time())}-{os.urandom(3).hex()}"
    subscriptions = [*previous, {"id": identifier, "name": label, "url": url}]
    previous_raw = SUBSCRIPTIONS_PATH.read_bytes() if SUBSCRIPTIONS_PATH.exists() else None
    try:
        write_subscriptions(subscriptions)
        return update_subscriptions(identifier)
    except Exception:
        if previous_raw is None:
            SUBSCRIPTIONS_PATH.unlink(missing_ok=True)
        else:
            SUBSCRIPTIONS_PATH.write_bytes(previous_raw)
            os.chmod(SUBSCRIPTIONS_PATH, 0o600)
        raise


def delete_subscription(value):
    identifier = normalize_subscription_id(value)
    previous = read_subscriptions()
    if identifier not in {item["id"] for item in previous}:
        raise ControlError("proxy_subscription_not_found")
    subscriptions = [item for item in previous if item["id"] != identifier]
    previous_raw = SUBSCRIPTIONS_PATH.read_bytes() if SUBSCRIPTIONS_PATH.exists() else None
    try:
        write_subscriptions(subscriptions)
        return update_subscriptions()
    except Exception:
        if previous_raw is None:
            SUBSCRIPTIONS_PATH.unlink(missing_ok=True)
        else:
            SUBSCRIPTIONS_PATH.write_bytes(previous_raw)
            os.chmod(SUBSCRIPTIONS_PATH, 0o600)
        raise


def enable_manual_mode():
    try:
        import yaml
    except ImportError as error:
        raise ControlError("proxy_manual_mode_unavailable") from error
    try:
        original = CONFIG_PATH.read_bytes()
        config = yaml.safe_load(original) or {}
    except (OSError, yaml.YAMLError) as error:
        raise ControlError("proxy_manual_mode_config_invalid") from error
    providers = config.get("proxy-providers") or {}
    if "dylian" not in providers:
        raise ControlError("proxy_manual_mode_config_invalid")
    groups = [item for item in (config.get("proxy-groups") or []) if isinstance(item, dict)]
    groups = [item for item in groups if item.get("name") not in {MANUAL_GROUP, MODE_GROUP}]
    groups.extend(
        [
            {"name": MANUAL_GROUP, "type": "select", "use": ["dylian"]},
            {"name": MODE_GROUP, "type": "select", "proxies": ["US-AUTO", MANUAL_GROUP, "DIRECT"]},
        ]
    )
    config["proxy-groups"] = groups
    rules = [str(item) for item in (config.get("rules") or [])]
    config["rules"] = [f"MATCH,{MODE_GROUP}" if item == "MATCH,US-AUTO" else item for item in rules]
    if not any(item.startswith("MATCH,") for item in config["rules"]):
        config["rules"].append(f"MATCH,{MODE_GROUP}")
    binary = shutil.which("mihomo")
    if not binary:
        raise ControlError("proxy_manual_mode_unavailable")
    handle, temp_path = tempfile.mkstemp(prefix=".config-", dir=CONFIG_PATH.parent)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as output:
            yaml.safe_dump(config, output, allow_unicode=True, sort_keys=False)
            output.flush()
            os.fsync(output.fileno())
        shutil.chown(temp_path, user="root", group="mihomo")
        os.chmod(temp_path, 0o640)
        run([binary, "-t", "-f", temp_path], timeout=30)
        os.replace(temp_path, CONFIG_PATH)
        run(["systemctl", "restart", "mihomo.service"], timeout=40)
    except Exception:
        if not os.path.exists(temp_path):
            CONFIG_PATH.write_bytes(original)
        else:
            os.unlink(temp_path)
        subprocess.run(["systemctl", "restart", "mihomo.service"], check=False, capture_output=True)
        raise
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


def test_nodes():
    if not service_active():
        raise ControlError("mihomo_service_inactive")
    controller_request(
        "GET",
        f"/providers/proxies/{PROVIDER_NAME}/healthcheck",
        timeout=60,
        attempts=1,
    )
    provider_entries = controller_request(
        "GET", f"/providers/proxies/{PROVIDER_NAME}"
    ).get("proxies", [])
    nodes = proxy_nodes({}, provider_entries)
    results = [
        {
            "name": item["name"],
            "ok": bool(item["alive"]) and item["delay"] > 0,
            "delay": item["delay"],
        }
        for item in nodes
    ]
    available = sum(1 for item in results if item["ok"])
    return {
        "tested": len(results),
        "available": available,
        "failed": len(results) - available,
        "nodes": results,
    }


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
    elif action == "add-subscription":
        response = add_subscription(request.get("name"), request.get("url"))
    elif action == "delete-subscription":
        response = delete_subscription(request.get("id"))
    elif action == "update-subscription":
        response = update_subscriptions(request.get("id") or "")
    elif action == "enable-manual-mode":
        response = enable_manual_mode()
    elif action == "set-service":
        response = set_service(request.get("enabled") is True)
    elif action == "set-group":
        response = set_group(request.get("group"), request.get("choice"))
    elif action == "test":
        response = test_proxy()
    elif action == "test-nodes":
        response = test_nodes()
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
