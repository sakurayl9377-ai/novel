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
    for path in (role, session):
        if not path.is_file():
            fail("KDJX game source is missing: {}".format(path))

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


if __name__ == "__main__":
    main()
