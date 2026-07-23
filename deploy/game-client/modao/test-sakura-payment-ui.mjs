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
    'static fromatPayPrice(t){let e="",a=(t/n.aaa.sConfigDataPool.getLine("164").parameter[0][0]).toFixed(2)',
  ),
  "cash prices no longer use the original RMB formatter",
);
assert.ok(
  panel.includes(
    'this.money_text.text="\u652f\u4ed8\u91d1\u989d:"+e+"\u5143"',
  ),
);
assert.ok(panel.includes("this.baseui.btn_alipay,this,this.onAlipayPay"));
assert.ok(panel.includes("this.baseui.btn_weixin,this,this.onWeixinPay"));
assert.ok(panel.includes("onWeixinPay()"));
assert.ok(panel.includes("onAlipayPay()"));
assert.ok(!panel.includes("\u6a31\u82b1\u5e01"));
assert.ok(
  panel.includes("beforeAdd(t){window.SakuraPaymentPanel=this,"),
  "payment panel is not available to the native payment result callback",
);
assert.ok(
  panel.includes(
    "window.SakuraPaymentPanel===this&&(window.SakuraPaymentPanel=null)",
  ),
  "payment panel handle is not cleared on close",
);
assert.ok(
  panel.includes(
    "i.off(this.baseui.btn_weixin,this,this.onWeixinPay),i.off(this.baseui.btn_alipay,this,this.onAlipayPay)",
  ),
  "payment action listeners are not removed when the panel closes",
);
assert.ok(
  source.includes(
    "if(window.SakuraBridge&&L.sakuraSession)return void window.SakuraBridge.openPayment(L,t,e)",
  ),
  "RMB payment choices do not route through Sakura payment",
);
assert.ok(
  source.includes(
    '-1!=["delivered","fulfilled","success"].indexOf(t)&&(a&&"function"==typeof a.removeSelf&&a.removeSelf(),S.showMessage("\\u652f\\u4ed8\\u6210\\u529f"))',
  ),
  "a delivered Sakura payment does not close the payment panel",
);
assert.ok(
  !source.includes(
    '["cancelled","failed","pending"].indexOf(t)&&(a&&"function"==typeof a.removeSelf',
  ),
  "a non-delivered Sakura payment must keep the payment panel open",
);

console.log("RMB display with Sakura payment routing tests passed");
