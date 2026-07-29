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
RECHARGE_CACHE_SCHEMA_ANCHOR = """type RechargeCache struct {
\t_struct struct{} `codec:",toarray"`

\tRechargeID int         `codec:"recharge_id" bson:"recharge_id"`
\tOrderID    document.ID `codec:"order_id" bson:"order_id"`
\tYYID       int         `codec:"yy_id" codec:"yy_id"`
\tCSVID      int         `codec:"csv_id" codec:"csv_id"`
}
"""
RECHARGE_CACHE_SCHEMA_REPLACEMENT = """type RechargeCache struct {
\t_struct struct{} `codec:",toarray"`

\tRechargeID int         `codec:"recharge_id" bson:"recharge_id"`
\tOrderID    document.ID `codec:"order_id" bson:"order_id"`
\tYYID       int         `codec:"yy_id" codec:"yy_id"`
\tCSVID      int         `codec:"csv_id" codec:"csv_id"`
\tRePro      int         `codec:"re_pro" bson:"re_pro"`
\tChannel    string      `codec:"channel" bson:"channel"`
}
"""
RPC_VERIFY_METHOD = "\tdef VerifySakuraPayment("
RPC_FULFILL_METHOD = "\tdef PayForRecharge("
OFFLINE_CACHE_ANCHOR = (
    "\t\t\t\trecharges_cache.append((rechargeID, orderID, yyID, csvID, rePro))\n"
)
OFFLINE_CACHE_REPLACEMENT = (
    "\t\t\t\trecharges_cache.append((rechargeID, orderID, yyID, csvID, "
    "rePro, channel))\n"
)
OFFLINE_REPLAY_ANCHOR = """\t\t\t\tif len(t)==4: # 可能存在的更新前的老订单
\t\t\t\t\trechargeID, orderID, yyID, csvID = t
\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID)
\t\t\t\telse:
\t\t\t\t\trechargeID, orderID, yyID, csvID, rePro = t
\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID, rePro=rePro)
"""
OFFLINE_REPLAY_REPLACEMENT = """\t\t\t\tif len(t)==4: # 可能存在的更新前的老订单
\t\t\t\t\trechargeID, orderID, yyID, csvID = t
\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID, channel='sakura')
\t\t\t\telif len(t) == 5:
\t\t\t\t\trechargeID, orderID, yyID, csvID, rePro = t
\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID, rePro=rePro, channel='sakura')
\t\t\t\telse:
\t\t\t\t\trechargeID, orderID, yyID, csvID, rePro, channel = t
\t\t\t\t\trole.buyRecharge(rechargeID, orderID, yyID, csvID, rePro=rePro, channel=channel or 'sakura')
"""


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


def replace_once(path, old, new, label):
    content = path.read_text(encoding="utf-8")
    if new in content:
        return
    if content.count(old) != 1:
        fail("{} source does not match the supported layout".format(label))
    path.write_text(content.replace(old, new, 1), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    game_service = root / "gosrc" / "tjgame" / "services" / "game" / "service.go"
    payment_bridge = root / "gosrc" / "tjgame" / "login" / "sakura_payments.go"
    role_schema = root / "gosrc" / "tjgame" / "document" / "scheme" / "Role.go"
    rpc = root / "release" / "src" / "game" / "rpc.py"
    game_handler = root / "release" / "src" / "game" / "handler" / "_game.py"
    for path in (game_service, payment_bridge, role_schema, rpc, game_handler):
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
    replace_once(
        role_schema,
        RECHARGE_CACHE_SCHEMA_ANCHOR,
        RECHARGE_CACHE_SCHEMA_REPLACEMENT,
        "offline recharge cache schema",
    )
    replace_once(
        rpc,
        OFFLINE_CACHE_ANCHOR,
        OFFLINE_CACHE_REPLACEMENT,
        "offline payment cache channel",
    )
    replace_once(
        game_handler,
        OFFLINE_REPLAY_ANCHOR,
        OFFLINE_REPLAY_REPLACEMENT,
        "offline payment replay channel",
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

    if OFFLINE_CACHE_REPLACEMENT not in rpc.read_text(encoding="utf-8"):
        fail("Sakura offline payment cache does not preserve its channel")
    role_schema_content = role_schema.read_text(encoding="utf-8")
    if (
        role_schema_content.count(
            'RePro      int         `codec:"re_pro" bson:"re_pro"`'
        )
        != 1
        or role_schema_content.count(
            'Channel    string      `codec:"channel" bson:"channel"`'
        )
        != 1
    ):
        fail("Sakura offline payment cache schema is incomplete")
    replay_content = game_handler.read_text(encoding="utf-8")
    if (
        "elif len(t) == 5:" not in replay_content
        or "channel='sakura'" not in replay_content
        or "channel=channel or 'sakura'" not in replay_content
    ):
        fail("Sakura offline payment replay does not preserve recharge values")


if __name__ == "__main__":
    main()
