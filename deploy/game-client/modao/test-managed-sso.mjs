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
  'EVENT_SAKURA_LOGIN_FAILURE="EVENT_SAKURA_LOGIN_FAILURE"',
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
assert.equal(count("EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure"), 2);
assert.equal(count('EVENT_SAKURA_LOGIN_FAILURE="EVENT_SAKURA_LOGIN_FAILURE"'), 1);
assert.equal(count("static sakuraLoginFailure(e)"), 1);
assert.equal(count("platform.sakuraLoginFailure(text(reason)"), 1);
assert.equal(count("T.once(50,this,this.onEnterTap)"), 0);
assert.equal(count("this.baseui.c2.selectedIndex=2,this.baseui.c1.selectedIndex=1"), 1);
assert.equal(
  count("2!=this.baseui.c2.selectedIndex&&(this.baseui.c2.selectedIndex=1)"),
  1,
);

for (const field of [
  "input_username",
  "input_passward",
  "input_inviteid",
  "input_passward_dup",
  "btn_login",
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

assert.equal(
  decodedLiteralAfter("hideSakuraLegacyLogin(),p.showMsg("),
  "正在通过小说 App 登录…",
);
assert.equal(
  decodedLiteralAfter("onSakuraLoginFailure(){p.showMsg("),
  "单点登录失败，请返回小说 App 后重新进入游戏",
);
assert.equal(
  decodedLiteralAfter(
    'd.showTip1(null,"\\u5355\\u70b9\\u767b\\u5f55\\u5931\\u8d25\\uff0c\\u8bf7\\u8fd4\\u56de\\u5c0f\\u8bf4 App \\u540e\\u91cd\\u65b0\\u8fdb\\u5165\\u6e38\\u620f",',
  ),
  "知道了",
);

console.log("managed SSO bundle tests passed");
