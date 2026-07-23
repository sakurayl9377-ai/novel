import assert from "node:assert/strict";

import { bypassDeadLegacyHotUpdate } from "./patch-hot-update.mjs";

const legacyStart =
  'prefix start(){if(console.log("Fest地址:"+r.getFestUrl()),""!=r.getFestUrl()){const ignored={nested:true};this.hotUpdate()}else this.gotoLogin()}setProgress(t){this.value=t} suffix';
const patched = bypassDeadLegacyHotUpdate(legacyStart);

assert.equal(
  patched,
  'prefix start(){this.baseui.lbl_version.text="Version:"+r.getVersionStr(),this.gotoLogin()}setProgress(t){this.value=t} suffix',
);
assert.doesNotMatch(patched, /getFestUrl|hotUpdate\(\)/);
assert.throws(
  () => bypassDeadLegacyHotUpdate(patched),
  /expected exactly one match, found 0/,
);
assert.throws(
  () => bypassDeadLegacyHotUpdate(`${legacyStart}\n${legacyStart}`),
  /expected exactly one match, found 2/,
);

console.log("hot update bypass tests passed");
