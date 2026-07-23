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
    "checkNeedSDKLogin(t){if(!L.isAndroid()&&!L.isIos())return!1;if(window.SakuraBridge&&window.SakuraBridge.managed(L))return window.SakuraBridge.start(L),!0;switch(L.operation_plat){case A.DEVTEST:return!1;default:return t?L.apkLogin():L.isAutoLogin?L.isAutoLogin=!1:L.apkLogin(),!0}}",
  );

  source = replaceOnce(
    source,
    "publish Sakura auth lifecycle and private state",
    'static sakuraPaymentResult(e){_.logSDK("Sakura payment result "+JSON.stringify(e))}static apkLoginCallBack',
    'static sakuraPaymentResult(e){_.logSDK("Sakura payment result "+JSON.stringify(e))}static sakuraPaymentFailure(e){_.logE("Sakura payment failed",e),S.showTip1(null,"\\u6a31\\u82b1\\u5e01\\u652f\\u4ed8\\u6682\\u4e0d\\u53ef\\u7528\\uff0c\\u8bf7\\u7a0d\\u540e\\u91cd\\u8bd5","\\u77e5\\u9053\\u4e86")}static sakuraLoginPending(){u.dispatch(L.EVENT_SAKURA_LOGIN_PENDING)}static sakuraLoginRequired(e){L.sakuraSession=!1,u.dispatch(L.EVENT_SAKURA_LOGIN_REQUIRED,String(e||"missing_session"))}static sakuraLoginFailure(e){L.sakuraSession=!1,u.dispatch(L.EVENT_SAKURA_LOGIN_FAILURE,String(e||"sso_failed"))}static sakuraReadAuthState(){return f.getLocalData("sakura_auth_state_v1","",!1)}static sakuraWriteAuthState(e){f.setLocalData("sakura_auth_state_v1",String(e||""),!1)}static sakuraCreateRequestId(){return L.toNativeCall("createSakuraRequestId",[],!0)}static sakuraOpenExternal(e){var t=L.callNative("openPayUrl",{url:e});try{return!1!==JSON.parse(t||"{}").ok}catch(e){return!0}}static sakuraOpenAuthorization(e){return L.sakuraOpenExternal(e)}static sakuraOpenPayment(e){return L.sakuraOpenExternal(e)}static apkLoginCallBack',
  );

  source = replaceOnce(
    source,
    "declare Sakura auth lifecycle events",
    'L.EVENT_SDK_LOGIN_SUCCESS="EVENT_SDK_LOGIN_SUCCESS",L.EVENT_PLATFORM_QRCODERESULT=',
    'L.EVENT_SDK_LOGIN_SUCCESS="EVENT_SDK_LOGIN_SUCCESS",L.EVENT_SAKURA_LOGIN_PENDING="EVENT_SAKURA_LOGIN_PENDING",L.EVENT_SAKURA_LOGIN_REQUIRED="EVENT_SAKURA_LOGIN_REQUIRED",L.EVENT_SAKURA_LOGIN_FAILURE="EVENT_SAKURA_LOGIN_FAILURE",L.EVENT_PLATFORM_QRCODERESULT=',
  );

  source = replaceOnce(
    source,
    "listen for Sakura auth lifecycle",
    "g.on(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.on(v.EVENT_PLATFORM_APPUPDATERESULT",
    "g.on(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.on(v.EVENT_SAKURA_LOGIN_PENDING,this,this.onSakuraLoginPending),g.on(v.EVENT_SAKURA_LOGIN_REQUIRED,this,this.onSakuraLoginRequired),g.on(v.EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure),g.on(v.EVENT_PLATFORM_APPUPDATERESULT",
  );

  source = replaceOnce(
    source,
    "remove Sakura auth lifecycle listeners",
    "g.off(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.off(v.EVENT_PLATFORM_APPUPDATERESULT",
    "g.off(v.EVENT_SDK_LOGIN_SUCCESS,this,this.onSDKLoginSuccess),g.off(v.EVENT_SAKURA_LOGIN_PENDING,this,this.onSakuraLoginPending),g.off(v.EVENT_SAKURA_LOGIN_REQUIRED,this,this.onSakuraLoginRequired),g.off(v.EVENT_SAKURA_LOGIN_FAILURE,this,this.onSakuraLoginFailure),g.off(v.EVENT_PLATFORM_APPUPDATERESULT",
  );

  source = replaceOnce(
    source,
    "mark dedicated package as managed login",
    "this._sakuraAutoLogin=!!(window.SakuraBridge&&(window.SakuraBridge.available()||window.SakuraBridge.configure(v,{}))),",
    "this._sakuraAutoLogin=!!(window.SakuraBridge&&window.SakuraBridge.managed(v)),",
  );

  source = replaceOnce(
    source,
    "show one Sakura authorization button",
    "this._sakuraAutoLogin&&T.once(500,this,(()=>v.checkNeedSDKLogin(!0)))}onNoticeReceive",
    'this._sakuraAutoLogin&&(this.showSakuraLoginButton(),T.once(50,this,(()=>window.SakuraBridge.start(v))))}showSakuraLoginButton(){["input_username","input_passward","input_inviteid","input_passward_dup","btn_reg","btn_reg_back","btn_change","combo_agree","btn_yhxy","btn_ysxy","btn_age"].forEach((e=>{var t=this.baseui[e];t&&(t.visible=!1)}));var e=this.baseui.btn_login;e.visible=!0,e.touchable=!0,e.grayed=!1,e.title="\\u6a31\\u82b1\\u767b\\u5f55",e.icon=""}onNoticeReceive',
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
    "show managed Sakura auth states without legacy fallback",
    "onSDKLoginFail(){this.baseui.c2.selectedIndex=1}",
    'onSakuraLoginPending(){p.showMsg("\\u6b63\\u5728\\u901a\\u8fc7\\u5c0f\\u8bf4 App \\u767b\\u5f55\\u2026",0,1,_.SCENE)}onSakuraLoginRequired(e,t){p.removeLoading(_.SCENE),this.baseui.c2.selectedIndex=1,this.showSakuraLoginButton(),"missing_session"!=t&&d.showMessage("\\u6388\\u6743\\u5df2\\u5931\\u6548\\uff0c\\u8bf7\\u70b9\\u51fb\\u6a31\\u82b1\\u767b\\u5f55\\u91cd\\u65b0\\u6388\\u6743")}onSakuraLoginFailure(e,t){p.removeLoading(_.SCENE),this.baseui.c2.selectedIndex=1,this.showSakuraLoginButton(),d.showTip1(null,"authorization_app_unavailable"==t?"\\u8bf7\\u5148\\u5b89\\u88c5\\u5c0f\\u8bf4 App \\u540e\\u91cd\\u8bd5":"\\u767b\\u5f55\\u5931\\u8d25\\uff0c\\u8bf7\\u70b9\\u51fb\\u6a31\\u82b1\\u767b\\u5f55\\u91cd\\u65b0\\u6388\\u6743","\\u77e5\\u9053\\u4e86")}onSDKLoginFail(){this.baseui.c2.selectedIndex=1}',
  );

  source = replaceOnce(
    source,
    "route managed login button to novel authorization",
    'onBtnLogin(){if(b.logD("确认登录"),',
    'onBtnLogin(){if(window.SakuraBridge&&window.SakuraBridge.managed(v))return void window.SakuraBridge.authorize(v);if(b.logD("确认登录"),',
  );

  source = replaceOnce(
    source,
    "stop at server selection after managed SSO",
    "this.baseui.lbl_servername.text=this._curSelectServerData.name,this._sakuraAutoLogin&&(this._sakuraAutoLogin=!1,T.once(50,this,this.onEnterTap))):b.logSDK",
    "this.baseui.lbl_servername.text=this._curSelectServerData.name,this._sakuraAutoLogin=!1):b.logSDK",
  );

  source = replaceOnce(
    source,
    "clear rejected managed session",
    "onRespKick(e){n.onRespKick(e)}",
    'onRespKick(e){window.SakuraBridge&&g.sakuraSession&&window.SakuraBridge.invalidate(g,"game_session_rejected"),n.onRespKick(e)}',
  );

  source = replaceOnce(
    source,
    "do not log Sakura game tokens",
    'console.log("apitoken",v.apitoken),',
    "",
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
