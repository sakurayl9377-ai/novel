import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function replaceOnce(source, label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

export function patchManagedSsoFlow(input) {
  let source = input;

  source = replaceOnce(
    source,
    "fail closed managed SDK login",
    "checkNeedSDKLogin(t){if(!L.isAndroid()&&!L.isIos())return!1;if(window.SakuraBridge&&(window.SakuraBridge.available()||window.SakuraBridge.configure(L,{})))return window.SakuraBridge.login(L),!0;switch(L.operation_plat){case A.DEVTEST:return!1;default:return t?L.apkLogin():L.isAutoLogin?L.isAutoLogin=!1:L.apkLogin(),!0}}",
    "checkNeedSDKLogin(t){if(!L.isAndroid()&&!L.isIos())return!1;if(window.SakuraBridge&&window.SakuraBridge.managed(L))return window.SakuraBridge.login(L),!0;switch(L.operation_plat){case A.DEVTEST:return!1;default:return t?L.apkLogin():L.isAutoLogin?L.isAutoLogin=!1:L.apkLogin(),!0}}",
  );

  source = replaceOnce(
    source,
    "publish Sakura login failure",
    'static sakuraPaymentResult(e){_.logSDK("Sakura payment result "+JSON.stringify(e))}static apkLoginCallBack',
    'static sakuraPaymentResult(e){_.logSDK("Sakura payment result "+JSON.stringify(e))}static sakuraLoginFailure(e){u.dispatch(L.EVENT_SAKURA_LOGIN_FAILURE,String(e||"sso_failed"))}static apkLoginCallBack',
  );

  source = replaceOnce(
    source,
    "declare Sakura login failure event",
    'L.EVENT_SDK_LOGIN_SUCCESS="EVENT_SDK_LOGIN_SUCCESS",L.EVENT_PLATFORM_QRCODERESULT=',
    'L.EVENT_SDK_LOGIN_SUCCESS="EVENT_SDK_LOGIN_SUCCESS",L.EVENT_SAKURA_LOGIN_FAILURE="EVENT_SAKURA_LOGIN_FAILURE",L.EVENT_PLATFORM_QRCODERESULT=',
  );

  source = replaceOnce(
    source,
    "listen for Sakura login failure",
    "g.on(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.on(v.EVENT_PLATFORM_APPUPDATERESULT",
    "g.on(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.on(v.EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure),g.on(v.EVENT_PLATFORM_APPUPDATERESULT",
  );

  source = replaceOnce(
    source,
    "remove Sakura login failure listener",
    "g.off(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.off(v.EVENT_PLATFORM_APPUPDATERESULT",
    "g.off(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.off(v.EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure),g.off(v.EVENT_PLATFORM_APPUPDATERESULT",
  );

  source = replaceOnce(
    source,
    "mark dedicated package as managed login",
    "this._sakuraAutoLogin=!!(window.SakuraBridge&&(window.SakuraBridge.available()||window.SakuraBridge.configure(v,{}))),",
    "this._sakuraAutoLogin=!!(window.SakuraBridge&&window.SakuraBridge.managed(v)),",
  );

  source = replaceOnce(
    source,
    "hide legacy login while managed SSO runs",
    "this._sakuraAutoLogin&&T.once(500,this,(()=>v.checkNeedSDKLogin(!0)))}onNoticeReceive",
    'this._sakuraAutoLogin&&(this.hideSakuraLegacyLogin(),p.showMsg("\\u6b63\\u5728\\u901a\\u8fc7\\u5c0f\\u8bf4 App \\u767b\\u5f55\\u2026",0,1,_.SCENE),T.once(500,this,(()=>v.checkNeedSDKLogin(!0))))}hideSakuraLegacyLogin(){["input_username","input_passward","input_inviteid","input_passward_dup","btn_login","btn_reg","btn_reg_back","btn_change","combo_agree","btn_yhxy","btn_ysxy","btn_age"].forEach((e=>{var t=this.baseui[e];t&&(t.visible=!1)}))}onNoticeReceive',
  );

  source = replaceOnce(
    source,
    "keep managed package off legacy login page",
    "determineLoginType(){v.isSDKLogin()?this.baseui.c2.selectedIndex=1:this.baseui.c2.selectedIndex=0,this.baseui.combo_agree.selected?this.baseui.c2.selectedIndex=0:d.showMessageNotice(335)}",
    "determineLoginType(){if(window.SakuraBridge&&window.SakuraBridge.managed(v))return void(2!=this.baseui.c2.selectedIndex&&(this.baseui.c2.selectedIndex=1));v.isSDKLogin()?this.baseui.c2.selectedIndex=1:this.baseui.c2.selectedIndex=0,this.baseui.combo_agree.selected?this.baseui.c2.selectedIndex=0:d.showMessageNotice(335)}",
  );

  source = replaceOnce(
    source,
    "remove managed login overlay after success",
    'onSDKLoginSuccess(){if(b.logSDK("fucksdk成功=========>")',
    'onSDKLoginSuccess(){if(p.removeLoading(_.SCENE),b.logSDK("fucksdk成功=========>")',
  );

  source = replaceOnce(
    source,
    "show managed SSO failure without legacy fallback",
    "onSDKLoginFail(){this.baseui.c2.selectedIndex=1}",
    'onSakuraLoginFailure(){p.showMsg("\\u5355\\u70b9\\u767b\\u5f55\\u5931\\u8d25\\uff0c\\u8bf7\\u8fd4\\u56de\\u5c0f\\u8bf4 App \\u540e\\u91cd\\u65b0\\u8fdb\\u5165\\u6e38\\u620f",0,1,_.SCENE),d.showTip1(null,"\\u5355\\u70b9\\u767b\\u5f55\\u5931\\u8d25\\uff0c\\u8bf7\\u8fd4\\u56de\\u5c0f\\u8bf4 App \\u540e\\u91cd\\u65b0\\u8fdb\\u5165\\u6e38\\u620f","\\u77e5\\u9053\\u4e86")}onSDKLoginFail(){this.baseui.c2.selectedIndex=1}',
  );

  source = replaceOnce(
    source,
    "stop at server selection after managed SSO",
    "this.baseui.lbl_servername.text=this._curSelectServerData.name,this._sakuraAutoLogin&&(this._sakuraAutoLogin=!1,T.once(50,this,this.onEnterTap))):b.logSDK",
    "this.baseui.lbl_servername.text=this._curSelectServerData.name,this._sakuraAutoLogin=!1):b.logSDK",
  );

  if (source.includes("T.once(50,this,this.onEnterTap)")) {
    throw new Error("managed SSO must not auto-enter a server");
  }
  return source;
}

export function refreshEmbeddedSakuraBridge(input, bridgeSource) {
  const marker = "\n;\n(function (root) {";
  const first = input.indexOf(marker);
  const second = first < 0 ? -1 : input.indexOf(marker, first + marker.length);
  if (first < 0 || second >= 0) {
    throw new Error("embedded Sakura bridge: expected exactly one match");
  }
  const normalizedBridge = bridgeSource.replace(/^\uFEFF/, "").trim();
  return input.slice(0, first) + "\n;\n" + normalizedBridge + "\n";
}

function isDirectInvocation() {
  if (!process.argv[1]) return false;
  return pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url;
}

if (isDirectInvocation()) {
  const target = process.argv[2];
  if (!target) {
    throw new Error("usage: node patch-managed-sso.mjs <index.js>");
  }
  const source = fs.readFileSync(target, "utf8");
  const bridgeSource = fs.readFileSync(
    new URL("./sakura-bridge.js", import.meta.url),
    "utf8",
  );
  const patched = patchManagedSsoFlow(source);
  fs.writeFileSync(
    target,
    refreshEmbeddedSakuraBridge(patched, bridgeSource),
    "utf8",
  );
}
