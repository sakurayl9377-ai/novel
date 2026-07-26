#!/usr/bin/env python3
import datetime
import json
import os
import subprocess
import sys

try:
    import fcntl
except ImportError:
    fcntl = None

SYSTEMCTL = "/usr/bin/systemctl"
LOCK_PATH = "/run/lock/novel-game-service-control.lock"
ALLOWED_ACTIONS = {"status", "start", "stop", "restart"}
SERVICE_GROUPS = {
    "bailian": (
        "bailian-game.service",
        "bailian-backstage.service",
    ),
    "modao": (
        "modao-redis.service",
        "modao-static.service",
        "modao-account.service",
        "modao-game.service",
    ),
    "kdjx": (
        "kdjx-mongodb.service",
        "kdjx-nsqlookupd.service",
        "kdjx-nsqd.service",
        "kdjx-host@accountdb.service",
        "kdjx-host@giftdb.service",
        "kdjx-host@storage1.service",
        "kdjx-host@storage2.service",
        "kdjx-host@pvp1.service",
        "kdjx-host@pvp2.service",
        "kdjx-host@crossdb.service",
        "kdjx-host@cross.service",
        "kdjx-anti-cheat.service",
        "kdjx-online-fight-forward.service",
        "kdjx-game@1.service",
        "kdjx-login.service",
        "kdjx-runtime.target",
    ),
}


def fail(code, exit_code=1):
    print(json.dumps({"ok": False, "error": code}, separators=(",", ":")))
    raise SystemExit(exit_code)


def systemctl(args, timeout=90):
    try:
        return subprocess.run(
            [SYSTEMCTL, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
            env={
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "LANG": "C",
                "LC_ALL": "C",
            },
        )
    except subprocess.TimeoutExpired:
        fail("game_control_timeout")
    except OSError:
        fail("game_control_service_unavailable")


def unit_status(unit):
    result = systemctl(
        [
            "show",
            unit,
            "--no-pager",
            "--property=LoadState",
            "--property=ActiveState",
            "--property=SubState",
            "--property=UnitFileState",
        ],
        timeout=15,
    )
    values = {}
    if result.returncode == 0:
        for line in result.stdout.splitlines():
            key, separator, value = line.partition("=")
            if separator:
                values[key] = value

    active_state = values.get("ActiveState", "unknown")
    load_state = values.get("LoadState", "unknown")
    unit_file_state = values.get("UnitFileState", "unknown").lower()
    if load_state != "loaded":
        status = "unknown"
    elif active_state == "active":
        status = "running"
    elif active_state == "inactive":
        status = "stopped"
    elif active_state == "failed":
        status = "failed"
    elif active_state == "activating":
        status = "activating"
    elif active_state == "deactivating":
        status = "deactivating"
    else:
        status = "unknown"

    return {
        "unit": unit,
        "status": status,
        "active": active_state == "active",
        "enabled": unit_file_state in {"enabled", "enabled-runtime"},
        "unitFileState": unit_file_state
        if unit_file_state.replace("-", "").replace("_", "").isalnum()
        else "unknown",
    }


def group_status(game_id, units):
    return {
        "gameId": game_id,
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "units": [unit_status(unit) for unit in units],
    }


def acquire_action_lock():
    if fcntl is None:
        fail("game_control_service_unavailable")
    try:
        handle = open(LOCK_PATH, "a+", encoding="utf-8")
        os.chmod(LOCK_PATH, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle
    except BlockingIOError:
        fail("game_control_busy")
    except OSError:
        fail("game_control_service_unavailable")


def run_action(game_id, action, units):
    if action != "status":
        if action == "start":
            command = ["enable", "--now", *units]
        elif action == "stop":
            command = ["disable", "--now", *tuple(reversed(units))]
        else:
            command = ["restart", *units]
        result = systemctl(command)
        if result.returncode != 0:
            fail("game_control_action_failed")

    data = group_status(game_id, units)
    if action in {"start", "restart"} and not all(
        unit["active"] for unit in data["units"]
    ):
        fail("game_control_state_mismatch")
    if action == "start" and not all(
        unit["enabled"] for unit in data["units"]
    ):
        fail("game_control_state_mismatch")
    if action == "stop" and not all(
        unit["status"] == "stopped" and not unit["enabled"]
        for unit in data["units"]
    ):
        fail("game_control_state_mismatch")
    print(json.dumps({"ok": True, "data": data}, separators=(",", ":")))


def main():
    if os.geteuid() != 0:
        fail("game_control_not_root")
    if len(sys.argv) != 3:
        fail("game_control_action_invalid")
    game_id = sys.argv[1]
    action = sys.argv[2]
    units = SERVICE_GROUPS.get(game_id)
    if units is None:
        fail("game_control_game_invalid")
    if action not in ALLOWED_ACTIONS:
        fail("game_control_action_invalid")
    if not os.path.isfile(SYSTEMCTL) or not os.access(SYSTEMCTL, os.X_OK):
        fail("game_control_service_unavailable")
    lock_handle = acquire_action_lock() if action != "status" else None
    try:
        run_action(game_id, action, units)
    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    main()
