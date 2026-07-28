#!/usr/bin/env python3
"""Generate the only runtime configuration accepted by the KDJX deployment."""

from __future__ import print_function

import argparse
import ipaddress
import json
import os
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import urlparse


PUBLIC_BACKEND_IP = "49.232.137.85"
DOWNLOAD_HOST = "novel.kxhub.xyz"
DOWNLOAD_BASE_URL = "https://novel.kxhub.xyz/games/kdjx/"
HOT_UPDATE_BASE_URL = "https://novel.kxhub.xyz/games/kdjx/hot/"
GUARDER_MD5 = "1b5a8aa9e7660d317d1eada5c37d2429"
LOOPBACK = "127.0.0.1"
MONGO_PORT = 27159
ALLOWED_RUNTIME_IPS = {PUBLIC_BACKEND_IP, LOOPBACK, "0.0.0.0"}


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def json_file(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )


def text_file(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")


def remove_path(path):
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(str(path))
    else:
        path.unlink()


def sanitize_disable_words(path):
    """Drop legacy endpoint literals from the shipped word-filter corpus.

    The legacy list contains historical service addresses as plain entries.
    They are not game content and retaining them makes the deployed runtime
    appear to target those systems. Keep every other filter token unchanged.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fail("cannot read disable_words.txt: {}".format(exc))

    retained = []
    for line in lines:
        token = line.strip()
        try:
            is_unapproved_ip = (
                bool(token) and str(ipaddress.ip_address(token)) == token and token not in ALLOWED_RUNTIME_IPS
            )
        except ValueError:
            is_unapproved_ip = False
        if not is_unapproved_ip:
            retained.append(line)
    text_file(path, "\n".join(retained) + "\n")


def replace_once(path, old, new, label):
    content = path.read_text(encoding="utf-8")
    if content.count(old) != 1:
        fail("{} does not match the supported source layout".format(label))
    text_file(path, content.replace(old, new, 1))


def replace_regex_once(path, pattern, replacement, label):
    content = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, content, count=1, flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        fail("{} does not match the supported source layout".format(label))
    text_file(path, updated)


def environment_value(name, default):
    return os.environ.get(name, default).strip()


def require_expected_address(name, value, expected):
    if value != expected:
        fail("{} must be {}".format(name, expected))
    return value


def validate_mongo_uri(value):
    parsed = urlparse(value)
    if (
        parsed.scheme != "mongodb"
        or parsed.hostname != LOOPBACK
        or parsed.port != MONGO_PORT
        or parsed.path not in ("", "/")
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        fail("KDJX_MONGO_URI must target mongodb://127.0.0.1:27159")
    return value


def base_container():
    return {
        "nsqlookupd": "http://127.0.0.1:4161/",
        "mainnsqd": "127.0.0.1:4150",
    }


def host_service(name, database, mongo_uri, aliases=None):
    service = {
        "name": name,
        "dbname": database,
        "mongodb": mongo_uri,
    }
    if aliases:
        service["alias"] = aliases
    return service


def pvp_services(shard):
    storage = "storage.cn.{}".format(shard)
    game = "game.cn.{}".format(shard)
    return [
        {"name": "pvp.cn.{}".format(shard), "dependent": [storage]},
        {
            "name": "yyhuodong.cn.{}".format(shard),
            "dependent": [storage, game],
        },
        {"name": "arena.cn.{}".format(shard), "dependent": [storage]},
        {"name": "union.cn.{}".format(shard), "dependent": [storage]},
        {"name": "card_fight.cn.{}".format(shard), "dependent": [storage]},
        {
            "name": "union_fight.cn.{}".format(shard),
            "dependent": ["anticheat", storage, game],
        },
        {
            "name": "craft.cn.{}".format(shard),
            "dependent": ["anticheat", storage, game],
        },
        {
            "name": "gym.cn.{}".format(shard),
            "dependent": ["anticheat", storage, game],
        },
        {"name": "clone.cn.{}".format(shard), "dependent": [storage]},
        {"name": "hunting.cn.{}".format(shard), "dependent": [storage]},
    ]


def cross_services():
    database = "crossdb.cn.1"
    return [
        {"name": "crossmatch.cn.1", "dependent": [database]},
        {"name": "crosscraft.cn.1", "dependent": ["anticheat", database]},
        {"name": "crossfishing.cn.1", "dependent": [database]},
        {"name": "huodongboss.cn.1", "dependent": [database]},
        {"name": "crossarena.cn.1", "dependent": ["anticheat", database]},
        {
            "name": "onlinefight.cn.1",
            "dependent": ["online_fight_forward", database],
        },
        {"name": "crossgym.cn.1", "dependent": ["anticheat", database]},
        {"name": "crossmine.cn.1", "dependent": ["anticheat", database]},
        {"name": "crossunionqa.cn.1", "dependent": [database]},
        {"name": "skyscraper.cn.1", "dependent": [database]},
        {"name": "crossredpacket.cn.1", "dependent": [database]},
        {"name": "crossranking.cn.1", "dependent": [database]},
        {"name": "crosshorse.cn.1", "dependent": [database]},
        {"name": "crossunionfight.cn.1", "dependent": [database]},
    ]


def write_host_config(root, mongo_uri):
    common = base_container()
    definitions = {
        "accountdb.cn.1": dict(
            common,
            services=[
                host_service(
                    "accountdb.cn.1",
                    "account",
                    mongo_uri,
                    aliases=["paymentdb.cn.1"],
                )
            ],
        ),
        "giftdb.cn.1": dict(
            common,
            services=[host_service("giftdb.cn.1", "gift", mongo_uri)],
        ),
        "storage.cn.1": dict(
            common,
            services=[host_service("storage.cn.1", "game1", mongo_uri)],
        ),
        "storage.cn.2": dict(
            common,
            services=[host_service("storage.cn.2", "game2", mongo_uri)],
        ),
        "crossdb.cn.1": dict(
            common,
            services=[host_service("crossdb.cn.1", "cross1", mongo_uri)],
        ),
        "pvp.cn.1": dict(common, services=pvp_services(1)),
        "pvp.cn.2": dict(common, services=pvp_services(2)),
        "cross.cn.1": dict(common, services=cross_services(), shushu=False),
    }
    json_file(root / "host" / "defines.json", definitions)


def write_login_config(root, public_ip):
    common = base_container()
    definitions = {
        "login.cn.1": dict(
            common,
            addr="0.0.0.0:16666",
            http_addr="127.0.0.1:18080",
            patch_url=HOT_UPDATE_BASE_URL,
            services=[
                {
                    "name": "login.cn.1",
                    "dependent": ["accountdb.cn.1", "game.cn.1"],
                }
            ],
        )
    }
    login = root / "login"
    json_file(login / "defines.json", definitions)
    conf = login / "conf"
    json_file(
        conf / "global.json",
        {
            "cn": {
                "game_key_prefix": ["game.cn"],
                "rmb_return": False,
                "newest": 1,
                "maintain": False,
                "maintain_servers": [],
                "maintain_billboard": "",
                "white_list_enable": False,
                "white_list_billboard": "",
                "white_list_all": [],
                "white_list": {},
                "register_disable": [],
                "check_isp": False,
                "check_isp_url": "",
                "shenhe_login": "",
            }
        },
    )
    servers = [
        {
            "id": 1,
            "key": "game.cn.1",
            "name": "Sakura I",
            "status": 1,
            "addr": "{}:28879".format(public_ip),
        },
    ]
    json_file(conf / "serv.json", servers)
    json_file(
        conf / "game.json",
        [
            {
                "key": server["key"],
                "addr": server["addr"],
                "open_date": "2026-07-26 00:00:00",
            }
            for server in servers
        ],
    )
    json_file(
        conf / "channel.json",
        {
            "channels": {"sakura": ["game.cn"]},
            "servers": {},
            "guarder": GUARDER_MD5,
        },
    )
    json_file(conf / "filter.json", {})
    json_file(conf / "notice.json", [])
    json_file(conf / "shenhe.json", {})
    json_file(conf / "patch_url.json", {"cn": {}})
    json_file(conf / "test.json", {"iplist": []})
    # An empty SDK config prevents legacy SDK verification from receiving a URL.
    json_file(conf / "sdk.json", {})
    json_file(
        conf / "cn" / "names.json",
        [
            {"id": 1, "key": "game.cn.1", "name": "Sakura I"},
        ],
    )
    json_file(
        conf / "cn" / "maintain.json",
        {"maintain": False, "maintain_servers": [], "maintain_billboard": ""},
    )
    json_file(conf / "cn" / "notice.json", [])
    json_file(login / "blacklist" / "global.json", {"black_list": []})
    (login / "patch" / "cn").mkdir(parents=True, exist_ok=True)
    (login / "patch_test" / "cn").mkdir(parents=True, exist_ok=True)


def write_python_runtime_config(root):
    release = root / "release"
    source = release / "src"
    if not source.is_dir():
        fail("Python source is missing: {}".format(source))
    sanitize_disable_words(release / "disable_words.txt")

    # These trees are operational tooling, tests, or legacy payment/cross-server
    # code. The KDJX runtime starts neither of them and must not retain their
    # credentials or historical endpoints.
    for relative in [
        "cross",
        "gm",
        "gm1",
        "gm_defines.py",
        "payment",
        "templates",
        "test",
        "new_server.py",
        "payment_defines.py",
    ]:
        remove_path(source / relative)
    remove_path(release / "payment_server.py")

    nsq_source = """# Generated by deploy/kdjx-backend; do not hand-edit.\n\nNSQDefs = {\n    'reader': {\n        'max_in_flight': 10,\n        'nsqd_tcp_addresses': ['127.0.0.1:4150'],\n        'output_buffer_size': 16 * 1024,\n        'output_buffer_timeout': 25,\n    },\n    'writer': {\n        'reconnect_interval': 5.0,\n        'nsqd_tcp_addresses': ['127.0.0.1:4150'],\n    },\n}\n\nCNNSQDefs = NSQDefs\nTRIALNSQDefs = NSQDefs\nKRNSQDefs = NSQDefs\nENNSQDefs = NSQDefs\nTWNSQDefs = NSQDefs\n"""
    text_file(release / "nsq_defines.py", nsq_source)
    text_file(release / "src" / "nsq_defines.py", nsq_source)
    game_defines = """# Generated by deploy/kdjx-backend; do not hand-edit.\nfrom datetime import datetime\nfrom nsq_defines import NSQDefs\n\nServerDefs = {\n    'game.cn.1': {\n        'ip': '127.0.0.1',\n        'port': 28879,\n        'nsq': NSQDefs,\n        'open_date': datetime(2026, 7, 26, 0),\n        'dependent': ['anticheat', 'giftdb.cn.1'],\n    },\n}\n"""
    text_file(release / "game_defines.py", game_defines)
    json_file(release / "sdk.conf", {})
    json_file(
        release / "serv.conf",
        [
            {
                "id": 1,
                "key": "game.cn.1",
                "name": "Sakura I",
                "url": "http://49.232.137.85:28879",
                "description": "",
            },
        ],
    )
    text_file(
        release / "payment_defines.py",
        "# Legacy inbound payment listener is intentionally disabled.\nServerDefs = {}\n",
    )
    anti_cheat = root / "anti-cheat"
    json_file(
        anti_cheat / "defines.json",
        {
            "agent.cn.1": dict(
                base_container(),
                services=[{"name": "anticheat", "error_not_force_result": False}],
            )
        },
    )
    online = root / "online-fight-forward"
    json_file(
        online / "defines.json",
        {
            "online_fight_forward.cn.1": {
                "debug": False,
                "ip": PUBLIC_BACKEND_IP,
                "nsqlookupd": "http://127.0.0.1:4161/",
                "nsqd_tcp_addresses": ["127.0.0.1:4150"],
                "services": [{"name": "online_fight_forward.cn.1"}],
            }
        },
    )
    # The running game imports these names, but no legacy callback or account
    # verification path is allowed to execute after the Go Sakura gate.
    sdk_stub = """# Sakura-only runtime. Legacy channel SDK calls fail closed.\n\nclass _DisabledLegacySDK(object):\n    Channel = ''\n\n    @classmethod\n    def initInGameServer(cls):\n        return None\n\n    @classmethod\n    def parseDataTokenToGame(cls, *args, **kwargs):\n        raise RuntimeError('legacy SDK payload is disabled')\n\n    @classmethod\n    def queryBalanceRequest(cls, *args, **kwargs):\n        raise RuntimeError('legacy SDK payment is disabled')\n\n    @classmethod\n    def payRequest(cls, *args, **kwargs):\n        raise RuntimeError('legacy SDK payment is disabled')\n\n\nclass SDKQQ(_DisabledLegacySDK):\n    Channel = 'qq'\n\n\nclass SDKWX(_DisabledLegacySDK):\n    Channel = 'wx'\n"""
    sdk_path = source / "payment" / "sdk"
    text_file(source / "payment" / "__init__.py", "# Sakura-only runtime package.\n")
    text_file(sdk_path / "__init__.py", "# Sakura-only runtime package.\n")
    text_file(sdk_path / "qq.py", sdk_stub)

    # The game imports discovery definitions, but the legacy discovery service
    # is not part of this topology. Keep an inert import-compatible module.
    remove_path(source / "discovery")
    text_file(source / "discovery" / "__init__.py", "# Sakura-only runtime package.\n")
    text_file(source / "discovery" / "defines.py", "# No external discovery service is configured.\nServerDefs = {}\n")
    text_file(
        source / "nsqrpc" / "defines.py",
        """# Generated by deploy/kdjx-backend; do not hand-edit.\n\nNSQLookups = ['http://127.0.0.1:4161']\nMainNSQ = ['127.0.0.1:4150']\nReaderNSQDefs = {'nsqd_tcp_addresses': MainNSQ}\nWriterNSQDefs = {'nsqd_tcp_addresses': MainNSQ}\n""",
    )
    # Production must not expose the legacy remote debugger or depend on the
    # external ThinkingData SDK. Preserve only the import contracts used by
    # the game so both capabilities stay inert and local.
    text_file(
        source / "rpdb.py",
        """# Generated by deploy/kdjx-backend; remote debugging is disabled.\n\nclass Rpdb(object):\n    def __init__(self, *args, **kwargs):\n        raise RuntimeError('remote debugger disabled')\n""",
    )
    text_file(source / "tgasdk" / "__init__.py", "# Local inert analytics adapter.\n")
    text_file(
        source / "tgasdk" / "sdk.py",
        """# Generated by deploy/kdjx-backend; external analytics is disabled.\n\nclass _Consumer(object):\n    def __init__(self, *args, **kwargs):\n        pass\n\n\nclass LoggingConsumer(_Consumer):\n    pass\n\n\nclass BatchConsumer(_Consumer):\n    pass\n\n\nclass AsyncBatchConsumer(_Consumer):\n    pass\n\n\nclass TGAnalytics(object):\n    def __init__(self, consumer):\n        self.consumer = consumer\n\n    def track(self, *args, **kwargs):\n        return None\n\n    def user_set(self, *args, **kwargs):\n        return None\n\n    def user_setOnce(self, *args, **kwargs):\n        return None\n\n    def flush(self):\n        return None\n""",
    )

    # Prevent startup/exception paths from calling historical Internet hosts.
    replace_once(
        source / "framework" / "monitor.py",
        "\t\ttempSock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n\t\ttempSock.connect(('8.8.8.8', 80))\n\t\taddr = tempSock.getsockname()[0]\n\t\ttempSock.close()",
        "\t\taddr = '127.0.0.1'",
        "framework monitor endpoint",
    )
    replace_regex_once(
        source / "framework" / "service" / "rpc_client.py",
        r"DINGHEADERS = \{.*?^\}\n.*?^def ding\(msg\):.*?(?=^def nsqrpc_coroutine)",
        "def ding(msg):\n\tlogger.warning('remote error notification disabled: %s', msg)\n\n",
        "framework alert endpoint",
    )
    endless = source / "game" / "object" / "game" / "endlesstower.py"
    replace_regex_once(
        endless,
        r"^\s*DingURL\s*=\s*[^\n]+\n",
        "\tDingURL = None\n",
        "endless tower alert endpoint",
    )
    replace_regex_once(
        endless,
        r"\t@classmethod\n\tdef ding\(cls, msg\):.*?\n\t\tif x\.status_code != 200:\n\t\t\tlogger\.warning\('%s', x\.text\)\n?",
        "\t@classmethod\n\tdef ding(cls, msg):\n\t\tlogger.warning('remote battle feedback disabled: %s', msg)\n",
        "endless tower alert delivery",
    )
    replace_once(
        endless,
        "import requests\n",
        "",
        "endless tower requests import",
    )
    replace_regex_once(
        source / "framework" / "log.py",
        r"\n# for test\nif __name__ == '__main__':(?:(?!\n# for test\nif __name__ == '__main__':).)*\Z",
        "\n",
        "framework log test fixture",
    )


def write_manifest(root, public_ip, mongo_uri):
    json_file(
        root / "runtime-manifest.json",
        {
            "schema_version": 1,
            "public_backend": public_ip,
            "download_base_url": DOWNLOAD_BASE_URL,
            "hot_update_base_url": HOT_UPDATE_BASE_URL,
            "mongo_uri": mongo_uri,
            "legacy_payment_listener": "disabled",
            "legacy_sdk": "disabled",
            "login_channel": "sakura",
            "gm_delivery": "loopback-hmac-mail-v1",
            "host_roles": [
                "accountdb",
                "giftdb",
                "storage1",
                "storage2",
                "pvp1",
                "pvp2",
                "crossdb",
                "cross",
            ],
        },
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", required=True)
    args = parser.parse_args()

    root = Path(args.runtime_root).resolve()
    if not root.is_dir():
        fail("runtime root does not exist: {}".format(root))

    public_ip = require_expected_address(
        "KDJX_PUBLIC_IP", environment_value("KDJX_PUBLIC_IP", PUBLIC_BACKEND_IP), PUBLIC_BACKEND_IP
    )
    mongo_uri = validate_mongo_uri(
        environment_value("KDJX_MONGO_URI", "mongodb://127.0.0.1:27159")
    )

    write_host_config(root, mongo_uri)
    write_login_config(root, public_ip)
    write_python_runtime_config(root)
    write_manifest(root, public_ip, mongo_uri)


if __name__ == "__main__":
    main()
