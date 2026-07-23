import assert from "node:assert/strict";
import fs from "node:fs";

const target = process.argv[2];
if (!target) {
  throw new Error("usage: node test-sakura-payment-ui.mjs <patched-index.js>");
}

const source = fs.readFileSync(target, "utf8");
const moduleStart = source.indexOf(
  'System.register("chunks:///_virtual/StorePaySelectPanel.ts"',
);
assert.notEqual(moduleStart, -1, "missing StorePaySelectPanel module");
const moduleEnd = source.indexOf("\nSystem.register(", moduleStart + 1);
const panel = source.slice(
  moduleStart,
  moduleEnd < 0 ? source.length : moduleEnd,
);

assert.ok(
  source.includes(
    'Math.round(10*e)+" \\u6a31\\u82b1\\u5e01":"-- \\u6a31\\u82b1\\u5e01"',
  ),
  "cash prices are not converted to Sakura coins at 10:1",
);
assert.ok(panel.includes("this.baseui.btn_weixin.visible=!1"));
assert.ok(panel.includes('a.title="\\u6a31\\u82b1\\u5e01\\u652f\\u4ed8"'));
assert.ok(
  panel.includes(
    'this.money_text.text="\\u9700\\u652f\\u4ed8\\uff1a"+Math.round(10*e)+" \\u6a31\\u82b1\\u5e01"',
  ),
);
assert.ok(panel.includes("a.x=(this.baseui.btn_weixin.x+a.x)/2"));
assert.ok(panel.includes("this.baseui.btn_alipay,this,this.onAlipayPay"));
assert.ok(!panel.includes("onWeixinPay()"));
assert.ok(!panel.includes('this.money_text.text="\\u652f\\u4ed8\\u91d1\\u989d:"'));

console.log("Sakura payment UI tests passed");
