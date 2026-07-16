#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest import mock


SCRIPT_PATH = Path(__file__).with_name("mihomo-subscription-update.py")
SPEC = importlib.util.spec_from_file_location("mihomo_subscription_update", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

ADMIN_SCRIPT_PATH = Path(__file__).with_name("mihomo-admin-control.py")
ADMIN_SPEC = importlib.util.spec_from_file_location(
    "mihomo_admin_control",
    ADMIN_SCRIPT_PATH,
)
ADMIN_MODULE = importlib.util.module_from_spec(ADMIN_SPEC)
ADMIN_SPEC.loader.exec_module(ADMIN_MODULE)


def resolver_for(mapping):
    def resolve(hostname, port, **_kwargs):
        return [
            (
                socket.AF_INET6 if ":" in address else socket.AF_INET,
                socket.SOCK_STREAM,
                socket.IPPROTO_TCP,
                "",
                (address, port),
            )
            for address in mapping[hostname]
        ]

    return resolve


class FakeResponse:
    def __init__(self, status, body=b"", headers=None):
        self.status = status
        self.body = body
        self.headers = headers or {}

    def getheader(self, name):
        return self.headers.get(name)

    def read(self, limit):
        return self.body[:limit]


class FakeConnection:
    def __init__(self, response):
        self.response = response
        self.request_target = ""

    def request(self, _method, target, headers=None):
        self.request_target = target

    def getresponse(self):
        return self.response

    def close(self):
        pass


class SubscriptionUpdateTests(unittest.TestCase):
    def test_admin_helper_rejects_whitespace_and_cgnat(self):
        with self.assertRaisesRegex(
            ADMIN_MODULE.ControlError,
            "proxy_subscription_url_invalid",
        ):
            ADMIN_MODULE.normalize_subscription_url(
                "https://subscription.example/list with space"
            )
        with mock.patch.object(
            ADMIN_MODULE.socket,
            "getaddrinfo",
            return_value=[
                (
                    socket.AF_INET,
                    socket.SOCK_STREAM,
                    socket.IPPROTO_TCP,
                    "",
                    ("100.64.0.1", 443),
                )
            ],
        ), self.assertRaisesRegex(
            ADMIN_MODULE.ControlError,
            "proxy_subscription_host_not_public",
        ):
            ADMIN_MODULE.normalize_subscription_url(
                "https://subscription.example/list"
            )

    def test_rejects_non_global_addresses_including_cgnat(self):
        for address in ("127.0.0.1", "169.254.169.254", "100.64.0.1", "::1"):
            with self.subTest(address=address), self.assertRaisesRegex(
                MODULE.SubscriptionUpdateError,
                "proxy_subscription_host_not_public",
            ):
                MODULE.resolve_public_addresses(
                    "subscription.example",
                    443,
                    resolver_for({"subscription.example": [address]}),
                )

    def test_pins_connection_to_validated_address(self):
        connections = []

        def factory(hostname, port, address, timeout, context):
            connections.append((hostname, port, address))
            return FakeConnection(FakeResponse(200, b'{"proxies":[]}'))

        body = MODULE.fetch_subscription(
            "https://subscription.example/list?token=test",
            resolver=resolver_for({"subscription.example": ["93.184.216.34"]}),
            connection_factory=factory,
        )
        self.assertEqual(body, b'{"proxies":[]}')
        self.assertEqual(
            connections,
            [("subscription.example", 443, "93.184.216.34")],
        )

    def test_rejects_http_redirect_before_second_connection(self):
        connections = []

        def factory(hostname, port, address, timeout, context):
            connections.append((hostname, address))
            return FakeConnection(
                FakeResponse(
                    302,
                    headers={"Location": "http://169.254.169.254/latest/meta-data"},
                )
            )

        with self.assertRaisesRegex(
            MODULE.SubscriptionUpdateError,
            "proxy_subscription_redirect_invalid",
        ):
            MODULE.fetch_subscription(
                "https://subscription.example/list",
                resolver=resolver_for({"subscription.example": ["93.184.216.34"]}),
                connection_factory=factory,
            )
        self.assertEqual(connections, [("subscription.example", "93.184.216.34")])

    def test_revalidates_https_redirect_destination(self):
        responses = [
            FakeResponse(302, headers={"Location": "https://internal.example/list"}),
        ]
        connections = []

        def factory(hostname, port, address, timeout, context):
            connections.append((hostname, address))
            return FakeConnection(responses.pop(0))

        with self.assertRaisesRegex(
            MODULE.SubscriptionUpdateError,
            "proxy_subscription_host_not_public",
        ):
            MODULE.fetch_subscription(
                "https://subscription.example/list",
                resolver=resolver_for(
                    {
                        "subscription.example": ["93.184.216.34"],
                        "internal.example": ["10.0.0.1"],
                    }
                ),
                connection_factory=factory,
            )
        self.assertEqual(connections, [("subscription.example", "93.184.216.34")])

    def test_bounds_response_body(self):
        def factory(hostname, port, address, timeout, context):
            return FakeConnection(FakeResponse(200, b"12345"))

        with self.assertRaisesRegex(
            MODULE.SubscriptionUpdateError,
            "proxy_subscription_response_too_large",
        ):
            MODULE.fetch_subscription(
                "https://subscription.example/list",
                resolver=resolver_for({"subscription.example": ["93.184.216.34"]}),
                connection_factory=factory,
                max_bytes=4,
            )

    def test_keeps_only_valid_proxy_payload(self):
        raw = (
            '\ufeff {"proxies":[{"name":"美国-A","server":"example.com"}],'
            '"secret":"drop-me"} trailing'
        ).encode("utf-8")
        payload = MODULE.build_provider_payload(
            [({"id": "one", "name": "主订阅", "url": "https://subscription.example/list"}, raw)]
        )
        self.assertEqual(
            json.loads(payload),
            {"proxies": [{"name": "[主订阅] 美国-A", "server": "example.com"}]},
        )
        self.assertNotIn(b"drop-me", payload)

    def test_supports_all_node_regions_and_deduplicates_names(self):
        payload = MODULE.build_provider_payload(
            [
                (
                    {"id": "one", "name": "订阅 A", "url": "https://one.example/list"},
                    b'{"proxies":[{"name":"Japan-A"}]}',
                ),
                (
                    {"id": "two", "name": "订阅 A", "url": "https://two.example/list"},
                    b'{"proxies":[{"name":"Japan-A"}]}',
                ),
            ]
        )
        self.assertEqual(
            [item["name"] for item in json.loads(payload)["proxies"]],
            ["[订阅 A] Japan-A", "[订阅 A] Japan-A #2"],
        )

    def test_reads_legacy_subscription_when_json_store_is_absent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / "subscription.env"
            legacy.write_text("SUBSCRIPTION_URL=https://subscription.example/list\n", encoding="utf-8")
            self.assertEqual(
                MODULE.read_subscriptions(root / "missing.json", legacy),
                [{"id": "legacy", "name": "默认订阅", "url": "https://subscription.example/list"}],
            )

    def test_tests_nodes_through_mihomo_delay_endpoint(self):
        runtime = {
            "US / One": {"alive": True, "history": []},
            "US-Two": {"alive": True, "history": []},
        }

        def fake_controller(method, path, payload=None, timeout=10, attempts=6):
            self.assertEqual(method, "GET")
            if path == "/proxies":
                return {"proxies": runtime}
            self.assertIn("/delay?", path)
            self.assertIn("url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204", path)
            self.assertEqual(attempts, 1)
            return {"delay": 42 if "US%20%2F%20One" in path else 84}

        nodes = [
            {"name": "US / One", "type": "ss", "alive": True, "delay": 0},
            {"name": "US-Two", "type": "ss", "alive": True, "delay": 0},
        ]
        with mock.patch.object(ADMIN_MODULE, "service_active", return_value=True), mock.patch.object(
            ADMIN_MODULE, "controller_request", side_effect=fake_controller
        ), mock.patch.object(ADMIN_MODULE, "proxy_nodes", return_value=nodes):
            result = ADMIN_MODULE.test_nodes()

        self.assertEqual(result["tested"], 2)
        self.assertEqual(result["available"], 2)
        self.assertEqual([item["delay"] for item in result["nodes"]], [42, 84])

    def test_rejects_unknown_node_latency_request(self):
        with mock.patch.object(ADMIN_MODULE, "service_active", return_value=True), mock.patch.object(
            ADMIN_MODULE, "controller_request", return_value={"proxies": {}}
        ), mock.patch.object(ADMIN_MODULE, "proxy_nodes", return_value=[]), self.assertRaisesRegex(
            ADMIN_MODULE.ControlError, "proxy_node_not_found"
        ):
            ADMIN_MODULE.test_nodes("missing")


if __name__ == "__main__":
    unittest.main()
