#!/usr/bin/env python3
"""Keep legacy KDJX role data from blocking game login."""

from __future__ import print_function

import argparse
import sys
from pathlib import Path


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    args = parser.parse_args()

    root = Path(args.source_root).resolve()
    role = root / "release" / "src" / "game" / "object" / "game" / "role.py"
    session = root / "release" / "src" / "game" / "session.py"
    union_training = (
        root
        / "gosrc"
        / "tjgame"
        / "services"
        / "union"
        / "training.go"
    )
    for path in (role, session, union_training):
        if not path.is_file():
            fail("KDJX game source is missing: {}".format(path))

    replace_once(
        role,
        """\tdef _initCardSkin(self):
\t\t# 初始化精灵皮肤属性加成
\t\tself._skinAdd = defaultdict(lambda:(zeros(), zeros()))
\t\tfor skinID in self.skins:
\t\t\tself.calCardSkinAttr(skinID)""",
        """\tdef _initCardSkin(self):
\t\t# 初始化精灵皮肤属性加成
\t\tself._skinAdd = defaultdict(lambda:(zeros(), zeros()))
\t\tfor skinID in self.skins.keys():
\t\t\tif csv.card_skin[skinID] is None:
\t\t\t\tlogger.warning(
\t\t\t\t\t'role %s removed skin %s missing from card_skin csv',
\t\t\t\t\tobjectid2string(self.id), skinID)
\t\t\t\tself.skins.pop(skinID, None)
\t\t\t\tcontinue
\t\t\tself.calCardSkinAttr(skinID)""",
        "invalid stored card skin cleanup",
    )
    replace_once(
        role,
        """\t\tskinID = specialArgsMap["skinID"]
\t\tdays = specialArgsMap["days"] or 0""",
        """\t\tskinID = specialArgsMap["skinID"]
\t\tif csv.card_skin[skinID] is None:
\t\t\tlogger.warning(
\t\t\t\t'role %s ignored item %s with missing card skin %s',
\t\t\t\tobjectid2string(self.id), itemID, skinID)
\t\t\treturn
\t\tdays = specialArgsMap["days"] or 0""",
        "invalid card skin activation compatibility",
    )
    replace_once(
        role,
        """\t\tfor skinID in skinIDs:
\t\t\tcfg = csv.card_skin[skinID]
\t\t\tif cfg.attrAddType == CardSkinDefs.sameMarkID:""",
        """\t\tfor skinID in skinIDs:
\t\t\tcfg = csv.card_skin[skinID]
\t\t\tif cfg is None:
\t\t\t\tlogger.warning(
\t\t\t\t\t'role %s skin %s missing from card_skin csv during refresh',
\t\t\t\t\tobjectid2string(self.id), skinID)
\t\t\t\tcontinue
\t\t\tif cfg.attrAddType == CardSkinDefs.sameMarkID:""",
        "card skin refresh compatibility",
    )
    replace_once(
        role,
        """\tdef calCardSkinAttr(self, skinID):
\t\tcfg = csv.card_skin[skinID]
\t\tmarkID = cfg.markID if cfg.attrAddType == CardSkinDefs.sameMarkID else 0""",
        """\tdef calCardSkinAttr(self, skinID):
\t\tcfg = csv.card_skin[skinID]
\t\tif cfg is None:
\t\t\tlogger.warning(
\t\t\t\t'role %s skin %s missing from card_skin csv during init',
\t\t\t\tobjectid2string(self.id), skinID)
\t\t\treturn
\t\tmarkID = cfg.markID if cfg.attrAddType == CardSkinDefs.sameMarkID else 0""",
        "card skin login compatibility",
    )
    replace_once(
        session,
        """\t\t\t\tfor skinID in skinsDeleted:
\t\t\t\t\tcardMarkID = csv.card_skin[skinID].markID
\t\t\t\t\tcards = game.cards.getCardsByMarkID(cardMarkID)""",
        """\t\t\t\tfor skinID in skinsDeleted:
\t\t\t\t\tcfg = csv.card_skin[skinID]
\t\t\t\t\tif cfg is None:
\t\t\t\t\t\tlogger.warning(
\t\t\t\t\t\t\t'skin %s missing from card_skin csv during expiry', skinID)
\t\t\t\t\t\tcontinue
\t\t\t\t\tcardMarkID = cfg.markID
\t\t\t\t\tcards = game.cards.getCardsByMarkID(cardMarkID)""",
        "card skin expiry compatibility",
    )
    replace_once(
        union_training,
        """import (
\t"math/rand"
\t"sync\"""",
        """import (
\t"math/rand"
\t"sort"
\t"sync\"""",
        "union training level fallback import",
    )
    replace_once(
        union_training,
        """func TrainingExpPerMinute(rolelevel, unionlevel int) int {
\tcfg := csv.GetConfig()
\tfix := cfg.Base_attribute.Role_level[rolelevel].UnionTrainingFix
\treturn int(cfg.Union.Union_level[unionlevel].TrainingExp * float64(fix))
}""",
        """func nearestConfiguredLevel(requested int, levels []int) (int, bool) {
\tif len(levels) == 0 {
\t\treturn 0, false
\t}
\tsort.Ints(levels)
\tindex := sort.SearchInts(levels, requested)
\tif index < len(levels) && levels[index] == requested {
\t\treturn requested, true
\t}
\tif index == 0 {
\t\treturn levels[0], true
\t}
\treturn levels[index-1], true
}

func TrainingExpPerMinute(rolelevel, unionlevel int) int {
\tcfg := csv.GetConfig()
\troleLevelCfg := cfg.Base_attribute.Role_level[rolelevel]
\tif roleLevelCfg == nil {
\t\tlevels := make([]int, 0, len(cfg.Base_attribute.Role_level))
\t\tfor level, candidate := range cfg.Base_attribute.Role_level {
\t\t\tif candidate != nil {
\t\t\t\tlevels = append(levels, level)
\t\t\t}
\t\t}
\t\tfallbackLevel, ok := nearestConfiguredLevel(rolelevel, levels)
\t\tif !ok {
\t\t\tlog.Errorf("union training has no configured role levels")
\t\t\treturn 0
\t\t}
\t\tlog.Warningf(
\t\t\t"union training role level %d missing, using level %d",
\t\t\trolelevel, fallbackLevel)
\t\troleLevelCfg = cfg.Base_attribute.Role_level[fallbackLevel]
\t}

\tunionLevelCfg := cfg.Union.Union_level[unionlevel]
\tif unionLevelCfg == nil {
\t\tlevels := make([]int, 0, len(cfg.Union.Union_level))
\t\tfor level, candidate := range cfg.Union.Union_level {
\t\t\tif candidate != nil {
\t\t\t\tlevels = append(levels, level)
\t\t\t}
\t\t}
\t\tfallbackLevel, ok := nearestConfiguredLevel(unionlevel, levels)
\t\tif !ok {
\t\t\tlog.Errorf("union training has no configured union levels")
\t\t\treturn 0
\t\t}
\t\tlog.Warningf(
\t\t\t"union training union level %d missing, using level %d",
\t\t\tunionlevel, fallbackLevel)
\t\tunionLevelCfg = cfg.Union.Union_level[fallbackLevel]
\t}

\treturn int(unionLevelCfg.TrainingExp * float64(roleLevelCfg.UnionTrainingFix))
}""",
        "union training missing level compatibility",
    )


if __name__ == "__main__":
    main()
