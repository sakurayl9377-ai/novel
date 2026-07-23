import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const legacyStartPattern =
  /start\(\)\{if\(console\.log\("Fest地址:"\+([A-Za-z_$][\w$]*)\.getFestUrl\(\)\),""!=\1\.getFestUrl\(\)\)\{.*?\}else this\.gotoLogin\(\)\}setProgress\(([A-Za-z_$][\w$]*)\)/gs;

export function bypassDeadLegacyHotUpdate(source) {
  const matches = [...source.matchAll(legacyStartPattern)];
  if (matches.length !== 1) {
    throw new Error(
      `dead legacy hot update bypass: expected exactly one match, found ${matches.length}`,
    );
  }

  return source.replace(
    legacyStartPattern,
    (_match, platformVariable, progressArgument) =>
      `start(){this.baseui.lbl_version.text="Version:"+${platformVariable}.getVersionStr(),this.gotoLogin()}setProgress(${progressArgument})`,
  );
}

function isDirectInvocation() {
  if (!process.argv[1]) return false;
  return pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
}

if (isDirectInvocation()) {
  const target = process.argv[2];
  if (!target) {
    throw new Error("usage: node patch-hot-update.mjs <index.js>");
  }

  const source = fs.readFileSync(target, "utf8");
  fs.writeFileSync(target, bypassDeadLegacyHotUpdate(source), "utf8");
}
