import assert from "node:assert/strict";
import fs from "node:fs";

import {
  patchManagedSsoFlow,
  refreshEmbeddedSakuraBridge,
} from "./patch-managed-sso.mjs";

const target = process.argv[2];
if (!target) {
  throw new Error("usage: node test-managed-sso.mjs <patched-baseline-index.js>");
}
const source = fs.readFileSync(target, "utf8");
const bridgeSource = fs.readFileSync(
  new URL("./sakura-bridge.js", import.meta.url),
  "utf8",
);
const patched = source.includes(
  'EVENT_SAKURA_LOGIN_REQUIRED="EVENT_SAKURA_LOGIN_REQUIRED"',
)
  ? source
  : refreshEmbeddedSakuraBridge(
      patchManagedSsoFlow(source),
      bridgeSource,
    );

function count(value) {
  return patched.split(value).length - 1;
}

function decodedLiteralAfter(marker) {
  const markerIndex = patched.indexOf(marker);
  assert.notEqual(markerIndex, -1, `missing marker: ${marker}`);
  const literalStart = patched.indexOf('"', markerIndex + marker.length);
  assert.notEqual(literalStart, -1, `missing string after: ${marker}`);
  const match = patched.slice(literalStart).match(/^"(?:\\.|[^"\\])*"/);
  assert.ok(match, `invalid string after: ${marker}`);
  return JSON.parse(match[0]);
}

assert.equal(count("window.SakuraBridge.managed(L)"), 1);
assert.equal(count("window.SakuraBridge.start(L)"), 1);
assert.equal(count("window.SakuraBridge.start(v)"), 1);
assert.equal(count("window.SakuraBridge.authorize(v)"), 1);
assert.equal(count("EVENT_SAKURA_LOGIN_PENDING,this,this.onSakuraLoginPending"), 2);
assert.equal(count("EVENT_SAKURA_LOGIN_REQUIRED,this,this.onSakuraLoginRequired"), 2);
assert.equal(count("EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure"), 2);
assert.equal(count('EVENT_SAKURA_LOGIN_PENDING="EVENT_SAKURA_LOGIN_PENDING"'), 1);
assert.equal(count('EVENT_SAKURA_LOGIN_REQUIRED="EVENT_SAKURA_LOGIN_REQUIRED"'), 1);
assert.equal(count('EVENT_SAKURA_LOGIN_FAILURE="EVENT_SAKURA_LOGIN_FAILURE"'), 1);
assert.equal(count("static sakuraReadAuthState()"), 1);
assert.equal(count("static sakuraWriteAuthState(e)"), 1);
assert.equal(count("static sakuraCreateRequestId()"), 1);
assert.equal(count("static sakuraOpenAuthorization(e)"), 1);
assert.equal(count("static sakuraOpenPayment(e)"), 1);
assert.equal(count("static sakuraPaymentFailure(e)"), 1);
assert.equal(count("T.once(50,this,this.onEnterTap)"), 0);
assert.equal(count("T.once(500,this,this.onBtnLogin)"), 0);
assert.equal(count("this.baseui.c2.selectedIndex=2,this.baseui.c1.selectedIndex=1"), 1);
assert.equal(
  count("2!=this.baseui.c2.selectedIndex&&(this.baseui.c2.selectedIndex=1)"),
  1,
);
assert.equal(
  count(
    'window.SakuraBridge&&g.sakuraSession&&window.SakuraBridge.invalidate(g,"game_session_rejected")',
  ),
  1,
);
assert.equal(count('console.log("apitoken",v.apitoken)'), 0);

for (const field of [
  "input_username",
  "input_passward",
  "input_inviteid",
  "input_passward_dup",
  "btn_reg",
  "btn_reg_back",
  "btn_change",
  "combo_agree",
  "btn_yhxy",
  "btn_ysxy",
  "btn_age",
]) {
  assert.ok(
    patched.includes(`"${field}"`),
    `managed SSO does not hide ${field}`,
  );
}
assert.ok(
  !patched.includes(
    '["input_username","input_passward","input_inviteid","input_passward_dup","btn_login"',
  ),
  "the Sakura login button must remain visible",
);

assert.equal(
  decodedLiteralAfter(
    "var e=this.baseui.btn_login;e.visible=!0,e.touchable=!0,e.grayed=!1,e.title=",
  ),
  "\u6a31\u82b1\u767b\u5f55",
);
assert.equal(
  decodedLiteralAfter("onSakuraLoginPending(){p.showMsg("),
  "\u6b63\u5728\u901a\u8fc7\u5c0f\u8bf4 App \u767b\u5f55\u2026",
);
assert.equal(
  decodedLiteralAfter('"missing_session"!=t&&d.showMessage('),
  "\u6388\u6743\u5df2\u5931\u6548\uff0c\u8bf7\u70b9\u51fb\u6a31\u82b1\u767b\u5f55\u91cd\u65b0\u6388\u6743",
);
assert.equal(
  decodedLiteralAfter('"authorization_app_unavailable"==t?'),
  "\u8bf7\u5148\u5b89\u88c5\u5c0f\u8bf4 App \u540e\u91cd\u8bd5",
);
assert.equal(
  decodedLiteralAfter(
    '"authorization_app_unavailable"==t?"\\u8bf7\\u5148\\u5b89\\u88c5\\u5c0f\\u8bf4 App \\u540e\\u91cd\\u8bd5":',
  ),
  "\u767b\u5f55\u5931\u8d25\uff0c\u8bf7\u70b9\u51fb\u6a31\u82b1\u767b\u5f55\u91cd\u65b0\u6388\u6743",
);
assert.equal(
  decodedLiteralAfter(
    'static sakuraPaymentFailure(e){_.logE("Sakura payment failed",e),S.showTip1(null,',
  ),
  "\u652f\u4ed8\u670d\u52a1\u6682\u4e0d\u53ef\u7528\uff0c\u8bf7\u7a0d\u540e\u91cd\u8bd5",
);

console.log("managed Sakura authorization bundle tests passed");
