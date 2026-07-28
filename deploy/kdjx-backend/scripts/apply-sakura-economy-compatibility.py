#!/usr/bin/env python3
"""Repair Sakura recharge values and virtual trainer experience delivery."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


ROLE_CONSTANTS_ANCHOR = "#\n# ObjectRole\n#\n\n"
ROLE_CONSTANTS = """# Sakura prices are yuan while role.rmb and VIP progress use diamonds.
SakuraRechargeRMB = {
	3: 6480,
	4: 3280,
	5: 1980,
	6: 980,
	7: 600,
	8: 300,
	9: 60,
}

# The inherited CSV granted these totals, including its malformed bonus value.
SakuraLegacyRechargeAward = {
	3: 130,
	4: 66,
	5: 40,
	6: 110,
	7: 12,
	8: 6,
	9: 2,
}

SakuraRechargeFixMarker = 'sakura_value_fix_v1'
SakuraTrainerExpItemID = 400

"""

RECHARGE_INIT_ANCHOR = """		self.game.chips.init()

		self._initMap()
"""
RECHARGE_INIT_REPLACEMENT = """		self.game.chips.init()

		self._applySakuraRechargeCompatibility()
		self._initMap()
"""

TRAINER_EXP_INIT_ANCHOR = """		self._inited = True

		self.onGrowGuideTask(TargetDefs.Level, 0)
"""
TRAINER_EXP_INIT_REPLACEMENT = """		self._inited = True

		self._applySakuraTrainerExperienceCompatibility()
		self.onGrowGuideTask(TargetDefs.Level, 0)
"""

ROLE_METHOD_ANCHOR = "\tdef _initMap(self):\n"
ROLE_METHODS = r'''	def _applySakuraRechargeCompatibility(self):
		compensation = 0
		orderCount = 0
		for rechargeID, correctRMB in SakuraRechargeRMB.iteritems():
			recharge = self.recharges.get(rechargeID, None)
			if not recharge or recharge.get(SakuraRechargeFixMarker, False):
				continue
			count = recharge.get('cnt', 0)
			if not isinstance(count, int) or count < 0:
				logger.warning(
					'role %s ignored invalid Sakura recharge count %s for %s',
					objectid2string(self.id), count, rechargeID)
				continue
			if count:
				compensation += count * (
					correctRMB - SakuraLegacyRechargeAward[rechargeID])
				orderCount += count
			recharge[SakuraRechargeFixMarker] = True
		if compensation:
			self.rmb += compensation
			logger.info(
				'role %s restored %d rmb from %d Sakura recharge orders',
				objectid2string(self.id), compensation, orderCount)

	def _applySakuraTrainerExperienceCompatibility(self):
		count = self.game.items.getItemCount(SakuraTrainerExpItemID)
		if count <= 0:
			return
		if not self.game.items.costItems({SakuraTrainerExpItemID: count}):
			logger.warning(
				'role %s could not convert %d trainer experience items',
				objectid2string(self.id), count)
			return
		try:
			self.exp += count
		except Exception:
			self.game.items.addItem(SakuraTrainerExpItemID, count)
			raise
		logger.info(
			'role %s converted %d trainer experience items to role exp',
			objectid2string(self.id), count)

'''

VIP_SUM_ANCHOR = "\t\t\tsumRMB += cnt * cfg.rmb\n"
VIP_SUM_REPLACEMENT = (
    "\t\t\tsumRMB += cnt * SakuraRechargeRMB.get(rechargeID, cfg.rmb)\n"
)
VIP_LEVEL_ANCHOR = "\t\tself.vip_level = level\n"
VIP_LEVEL_REPLACEMENT = "\t\tself.vip_level = max(self.vip_level, level)\n"

RECHARGE_VALUE_ANCHOR = """		rePro = kwargs.get('rePro', 0) # 返利比例
		if rePro > 0: # lunplay h5充值返利
			from math import ceil
			rmb += int(ceil(cfg.rmb * (rePro * 1.0 / 100)))

		def done():
"""
RECHARGE_VALUE_REPLACEMENT = """		rePro = kwargs.get('rePro', 0) # 返利比例
		if rePro > 0: # lunplay h5充值返利
			from math import ceil
			rmb += int(ceil(cfg.rmb * (rePro * 1.0 / 100)))

		sakuraRMB = None
		if kwargs.get('channel', None) == 'sakura':
			sakuraRMB = SakuraRechargeRMB.get(rechargeID, None)
			if sakuraRMB is not None:
				rmb = sakuraRMB

		def done():
"""

# Some production source snapshots omit the historical comments in the
# block above. Anchor this replacement to executable code instead.
RECHARGE_VALUE_STABLE_ANCHOR = (
    "\t\t\trmb += int(ceil(cfg.rmb * (rePro * 1.0 / 100)))\n"
    "\n"
    "\t\tdef done():\n"
)
RECHARGE_VALUE_STABLE_REPLACEMENT = (
    "\t\t\trmb += int(ceil(cfg.rmb * (rePro * 1.0 / 100)))\n"
    "\n"
    "\t\tsakuraRMB = None\n"
    "\t\tif kwargs.get('channel', None) == 'sakura':\n"
    "\t\t\tsakuraRMB = SakuraRechargeRMB.get(rechargeID, None)\n"
    "\t\t\tif sakuraRMB is not None:\n"
    "\t\t\t\trmb = sakuraRMB\n"
    "\n"
    "\t\tdef done():\n"
)

RECHARGE_DONE_ANCHOR = """			if orderID != TestOrderID:
				orders.append(orderID)
"""
RECHARGE_DONE_REPLACEMENT = """			if orderID != TestOrderID:
				orders.append(orderID)
			if kwargs.get('channel', None) == 'sakura':
				recharge[SakuraRechargeFixMarker] = True
"""

RECHARGE_PROGRESS_ANCHOR = """		self.game.dailyRecord.recharge_rmb_sum += cfg.rmb
		if cfg.validRechargeHuodong:
			ObjectYYHuoDongFactory.onRecharge(self.game, cfg.rmb, rechargeID)
"""
RECHARGE_PROGRESS_REPLACEMENT = """		rechargeRMB = sakuraRMB if sakuraRMB is not None else cfg.rmb
		self.game.dailyRecord.recharge_rmb_sum += rechargeRMB
		if cfg.validRechargeHuodong:
			ObjectYYHuoDongFactory.onRecharge(self.game, rechargeRMB, rechargeID)
"""


def fail(message):
    print("error: {}".format(message), file=sys.stderr)
    raise SystemExit(2)


def replace_once(path, old, new, label):
    content = path.read_text(encoding="utf-8")
    if new in content:
        return
    if content.count(old) != 1:
        fail("{} does not match the supported source layout".format(label))
    path.write_text(content.replace(old, new, 1), encoding="utf-8")


def insert_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} does not match the supported source layout".format(label))
    path.write_text(content.replace(anchor, anchor + addition, 1), encoding="utf-8")


def insert_before_once(path, anchor, addition, label):
    content = path.read_text(encoding="utf-8")
    if addition in content:
        return
    if content.count(anchor) != 1:
        fail("{} does not match the supported source layout".format(label))
    path.write_text(content.replace(anchor, addition + anchor, 1), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    role = root / "release" / "src" / "game" / "object" / "game" / "role.py"
    if not role.is_file():
        fail("KDJX role source is missing: {}".format(role))

    insert_once(role, ROLE_CONSTANTS_ANCHOR, ROLE_CONSTANTS, "role constants")
    replace_once(
        role,
        RECHARGE_INIT_ANCHOR,
        RECHARGE_INIT_REPLACEMENT,
        "recharge compatibility initialization",
    )
    replace_once(
        role,
        TRAINER_EXP_INIT_ANCHOR,
        TRAINER_EXP_INIT_REPLACEMENT,
        "trainer experience compatibility initialization",
    )
    insert_before_once(role, ROLE_METHOD_ANCHOR, ROLE_METHODS, "role compatibility")
    replace_once(role, VIP_SUM_ANCHOR, VIP_SUM_REPLACEMENT, "VIP recharge sum")
    replace_once(role, VIP_LEVEL_ANCHOR, VIP_LEVEL_REPLACEMENT, "VIP floor")
    replace_once(
        role,
        RECHARGE_VALUE_STABLE_ANCHOR,
        RECHARGE_VALUE_STABLE_REPLACEMENT,
        "Sakura recharge value",
    )
    replace_once(
        role,
        RECHARGE_DONE_ANCHOR,
        RECHARGE_DONE_REPLACEMENT,
        "Sakura recharge migration marker",
    )
    replace_once(
        role,
        RECHARGE_PROGRESS_ANCHOR,
        RECHARGE_PROGRESS_REPLACEMENT,
        "Sakura recharge progress",
    )

    content = role.read_text(encoding="utf-8")
    required = (
        "SakuraRechargeRMB = {",
        "SakuraLegacyRechargeAward = {",
        "def _applySakuraRechargeCompatibility(self):",
        "def _applySakuraTrainerExperienceCompatibility(self):",
        "self.vip_level = max(self.vip_level, level)",
        "rmb = sakuraRMB",
        "recharge[SakuraRechargeFixMarker] = True",
    )
    if any(marker not in content for marker in required):
        fail("Sakura economy compatibility patch is incomplete")


if __name__ == "__main__":
    main()
