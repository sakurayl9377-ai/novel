#!/usr/bin/env python3
"""Register the Sakura payment methods in the KDJX remote game stub."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


GAME_SERVICE_CONSTRUCTOR_ANCHOR = (
    "func NewService(option service.IOption, container service.IContainer) service.IService {\n"
)
GAME_SERVICE_REGISTER_ANCHOR = '\ts.Register(s, "GetOpenDays")\n'
GAME_SERVICE_METHODS = r'''func (s *Service) VerifySakuraPayment(inlPwd string, rechargeID int, amountYuan string, yyID int, csvID int) (response string, err error) {
	return
}

func (s *Service) PayForRecharge(inlPwd string, channel string, accountID document.ID, roleID document.ID, rechargeID int, orderID document.ID, amount float64, extInfo interface{}, yyID int, csvID int) (response string, err error) {
	return
}

'''
GAME_SERVICE_REGISTERS = (
    '\ts.Register(s, "VerifySakuraPayment")\n'
    '\ts.Register(s, "PayForRecharge")\n'
)
RPC_VERIFY_METHOD = "\tdef VerifySakuraPayment("
RPC_FULFILL_METHOD = "\tdef PayForRecharge("


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def patch_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} source does not match the supported layout".format(label))
    path.write_text(content.replace(anchor, anchor + addition, 1), encoding="utf-8")


def patch_before_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} source does not match the supported layout".format(label))
    path.write_text(content.replace(anchor, addition + anchor, 1), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    game_service = root / "gosrc" / "tjgame" / "services" / "game" / "service.go"
    payment_bridge = root / "gosrc" / "tjgame" / "login" / "sakura_payments.go"
    rpc = root / "release" / "src" / "game" / "rpc.py"
    for path in (game_service, payment_bridge, rpc):
        if not path.is_file():
            fail("required KDJX payment source is missing: {}".format(path))

    bridge_content = payment_bridge.read_text(encoding="utf-8")
    for required in (
        'Handle("/internal/sakura/payments/verify"',
        'Handle("/internal/sakura/payments/fulfill"',
        '"VerifySakuraPayment"',
        '"PayForRecharge"',
    ):
        if bridge_content.count(required) != 1:
            fail("Sakura payment bridge is incomplete: {}".format(required))

    rpc_content = rpc.read_text(encoding="utf-8")
    if (
        rpc_content.count(RPC_VERIFY_METHOD) != 1
        or rpc_content.count(RPC_FULFILL_METHOD) != 1
        or "GameServInternalPassword" not in rpc_content
        or "csv.recharges" not in rpc_content
        or "raise Return('ok')" not in rpc_content
    ):
        fail("Sakura payment game RPC implementation is incomplete")

    patch_before_once(
        game_service,
        GAME_SERVICE_CONSTRUCTOR_ANCHOR,
        GAME_SERVICE_METHODS,
        "game service payment RPC stubs",
    )
    patch_once(
        game_service,
        GAME_SERVICE_REGISTER_ANCHOR,
        GAME_SERVICE_REGISTERS,
        "game service payment RPC registration",
    )

    service_content = game_service.read_text(encoding="utf-8")
    for method in ("VerifySakuraPayment", "PayForRecharge"):
        if (
            service_content.count("func (s *Service) {}(".format(method)) != 1
            or service_content.count('s.Register(s, "{}")'.format(method)) != 1
            or service_content.index("func (s *Service) {}(".format(method))
            > service_content.index(GAME_SERVICE_CONSTRUCTOR_ANCHOR)
        ):
            fail("Sakura payment RPC registration is incomplete: {}".format(method))


if __name__ == "__main__":
    main()
