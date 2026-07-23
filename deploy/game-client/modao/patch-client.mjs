import fs from "node:fs";

import { bypassDeadLegacyHotUpdate } from "./patch-hot-update.mjs";
import { patchManagedSsoFlow } from "./patch-managed-sso.mjs";
import { patchSakuraPaymentUi } from "./patch-sakura-payment-ui.mjs";

const args = process.argv.slice(2);
const skipReconnect = args.includes("--skip-reconnect");
const target = args.find((value) => !value.startsWith("--"));
if (!target) {
  throw new Error("usage: node patch-client.mjs [--skip-reconnect] <index.js>");
}

let source = fs.readFileSync(target, "utf8");
const bridgeSource = fs.readFileSync(
  new URL("./sakura-bridge.js", import.meta.url),
  "utf8",
);

function replaceOnce(label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  source = source.slice(0, first) + after + source.slice(first + before.length);
}

function replaceRegexOnce(label, pattern, replacement) {
  const matches = source.match(new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`));
  if (!matches || matches.length !== 1) {
    throw new Error(`${label}: expected exactly one match`);
  }
  source = source.replace(pattern, replacement);
}

function replaceAny(label, variants) {
  const matches = variants.filter(([before]) => {
    const first = source.indexOf(before);
    return first >= 0 && source.indexOf(before, first + before.length) < 0;
  });
  if (matches.length !== 1) {
    throw new Error(`${label}: expected exactly one supported baseline`);
  }
  replaceOnce(label, matches[0][0], matches[0][1]);
}

if (!skipReconnect) {
  replaceOnce(
    "GNet reconnect controls",
    "static startReconnect(){r.gamenetManager.startReconnect()}static setNeedReconnect(e){r.gamenetManager.setNeedReconnect(e)}",
    "static startReconnect(){r.gamenetManager.startReconnect()}static checkReconnect(){r.gamenetManager.checkReconnect()}static resetReconnect(){r.gamenetManager.resetReconnect()}static setNeedReconnect(e){r.gamenetManager.setNeedReconnect(e)}",
  );
}

replaceOnce(
  "read Sakura launch config",
  'let e={};try{e=JSON.parse(t)}catch(t){return void _.logE("获取游戏配置失败",t.message)}"1"==e.app_isLatest?',
  'let e={};try{e=JSON.parse(t)}catch(t){return void _.logE("获取游戏配置失败",t.message)}window.SakuraBridge&&window.SakuraBridge.configure(L,e),"1"==e.app_isLatest?',
);

replaceOnce(
  "prefer Sakura SSO over the legacy SDK",
  "checkNeedSDKLogin(t){if(!L.isAndroid()&&!L.isIos())return!1;switch(L.operation_plat){case A.DEVTEST:return!1;default:return t?L.apkLogin():L.isAutoLogin?L.isAutoLogin=!1:L.apkLogin(),!0}}",
  "checkNeedSDKLogin(t){if(!L.isAndroid()&&!L.isIos())return!1;if(window.SakuraBridge&&(window.SakuraBridge.available()||window.SakuraBridge.configure(L,{})))return window.SakuraBridge.login(L),!0;switch(L.operation_plat){case A.DEVTEST:return!1;default:return t?L.apkLogin():L.isAutoLogin?L.isAutoLogin=!1:L.apkLogin(),!0}}",
);

replaceOnce(
  "publish the Sakura server list",
  "static reqServerList(){var t=L.phpApiUrl+\"serverlist?\";",
  "static reqServerList(){if(L.sakuraSession)return void L.sakuraPublishServerList();var t=L.phpApiUrl+\"serverlist?\";",
);

replaceOnce(
  "publish the Sakura server detail",
  "static reqServerDetail(t){var e=L.phpApiUrl+\"serverinfo?\";",
  "static reqServerDetail(t){if(L.sakuraSession)return void L.sakuraPublishServerDetail(t);var e=L.phpApiUrl+\"serverinfo?\";",
);

replaceOnce(
  "Sakura server list requirement",
  "static checkNeedReqServerList(){if(!L.isAndroid()&&!L.isIos())return!1;switch(L.operation_plat){case A.DEVTEST:return!1;default:return L.reqServerList(),!0}}",
  "static checkNeedReqServerList(){if(L.sakuraSession)return L.reqServerList(),!0;if(!L.isAndroid()&&!L.isIos())return!1;switch(L.operation_plat){case A.DEVTEST:return!1;default:return L.reqServerList(),!0}}",
);

replaceOnce(
  "Sakura server detail requirement",
  "static checkNeedReqServerDetail(t){if(!L.isAndroid()&&!L.isIos())return!1;switch(L.operation_plat){case A.DEVTEST:return!1;default:return L.reqServerDetail(t),!0}}",
  "static checkNeedReqServerDetail(t){if(L.sakuraSession)return L.reqServerDetail(t),!0;if(!L.isAndroid()&&!L.isIos())return!1;switch(L.operation_plat){case A.DEVTEST:return!1;default:return L.reqServerDetail(t),!0}}",
);

if (!skipReconnect) {
  replaceRegexOnce(
    "retry failed websocket connection",
    /reconnectFail\(\)\{a\.logE\([^)]*\)\}/,
    'reconnectFail(){a.logE("reconnect transport failed"),r.checkReconnect()}',
  );

  replaceRegexOnce(
    "reset reconnect attempts and fall back to full login",
    /onRespReconnect\(a\)\{switch\(n\.removeLoading\(\),a\.code\)\{.*?\}e\.dispatch\(M\.EVENT_RECONNECT_FINISH\)\}/s,
    'onRespReconnect(a){switch(n.removeLoading(),a.code){case 0:i.logD("reconnect success"),E.resetReconnect();break;case 1:case 2:i.logD("fast reconnect expired; starting full login"),E.setNeedReconnect(!1),s.forceReLoad();break;default:i.logD("reconnect rejected; starting full login"),E.setNeedReconnect(!1),s.forceReLoad()}e.dispatch(M.EVENT_RECONNECT_FINISH)}',
  );

  replaceOnce(
    "foreground network recovery",
    'case"pause":o.pause();break;case"adplaycomplet"',
    'case"pause":window.GNet&&window.GNet.pause(),o.pause();break;case"resume":o.resume(),window.SakuraBridge&&window.SakuraBridge.onResume(L),window.GNet&&(window.GNet.resume(),window.GNet.isConnect()?window.GNet.forceHeartbeat():window.GNet.needReconnecting()&&window.GNet.checkReconnect());break;case"adplaycomplet"',
  );
} else {
  // A repaired baseline may expose GNet already; a plain baseline only needs
  // the Sakura payment callback on resume when reconnect edits are skipped.
  replaceAny("foreground Sakura resume hook", [
    [
      'case"resume":o.resume(),window.GNet&&(window.GNet.resume(),window.GNet.isConnect()?window.GNet.forceHeartbeat():window.GNet.needReconnecting()&&window.GNet.checkReconnect());break;case"adplaycomplet"',
      'case"resume":o.resume(),window.SakuraBridge&&window.SakuraBridge.onResume(L),window.GNet&&(window.GNet.resume(),window.GNet.isConnect()?window.GNet.forceHeartbeat():window.GNet.needReconnecting()&&window.GNet.checkReconnect());break;case"adplaycomplet"',
    ],
    [
      'case"pause":o.pause();break;case"adplaycomplet"',
      'case"pause":o.pause();break;case"resume":o.resume(),window.SakuraBridge&&window.SakuraBridge.onResume(L);break;case"adplaycomplet"',
    ],
  ]);
}

replaceOnce(
  "Sakura native login result and server data",
  'static apkLogin(){L.toNativeCall("login")}',
  'static apkLogin(){L.toNativeCall("login")}static sakuraLoginSuccess(e){L.userId=String(e.accountId||""),L.apitoken=String(e.token||""),L.sakuraServerInfo=e.serverInfo||void 0,L.sakuraSession=!0,u.dispatch(L.EVENT_SDK_LOGIN_SUCCESS)}static sakuraPublishServerList(){var e=L.sakuraServerInfo&&L.sakuraServerInfo.data?L.sakuraServerInfo.data:{},t={sid:String(e.sid||"1"),name:e.name||"主服务器",hot:"1",open_time:"0",wait_open:0,open_date:"",status:1,ip:e.ip||"",token:e.token||"",port:Number(e.port||0)},a={code:1,msg:"ok",data:{server_list:[t],last_server_list:[t.sid],server_role_info:[]}};f.myLoginInfoPool.allServerInfo=a,u.dispatch(p.EVENT_GET_SERVER_LIST)}static sakuraPublishServerDetail(){var e=L.sakuraServerInfo&&L.sakuraServerInfo.data?L.sakuraServerInfo.data:{},t={code:"1",msg:"ok",data:{sid:String(e.sid||"1"),name:e.name||"主服务器",ip:e.ip||"",port:Number(e.port||0),token:e.token||""}};u.dispatch(p.EVENT_GET_SERVER_DETAIL,t)}static sakuraPaymentResult(e){_.logSDK("Sakura payment result "+JSON.stringify(e))}',
);

if (!skipReconnect) {
  replaceOnce(
    "expose GNet for lifecycle recovery",
    'e("GNet",r),r.gamenetManager=void 0,r._reqId=0',
    'e("GNet",r),window.GNet=r,r.gamenetManager=void 0,r._reqId=0',
  );
}

const ssoAutoLoginExpression =
  'this._sakuraAutoLogin=!!(window.SakuraBridge&&(window.SakuraBridge.available()||window.SakuraBridge.configure(v,{}))),';
const ssoAutoLoginPattern =
  /this\._sakuraAutoLogin=!!\(window\.SakuraBridge&&\(window\.SakuraBridge\.available\(\)\|\|window\.SakuraBridge\.configure\([A-Za-z_$][\w$]*,\{\}\)\)\),/;
if (ssoAutoLoginPattern.test(source)) {
  source = source.replace(ssoAutoLoginPattern, ssoAutoLoginExpression);
} else {
  replaceOnce(
    "Sakura cold-start marker",
    'this.baseui.input_passward.text=u.getLocalData("password","",!1),',
    'this.baseui.input_passward.text=u.getLocalData("password","",!1),' +
      ssoAutoLoginExpression,
  );
}
const legacyAutoLoginState =
  'this._sakuraAutoLogin=""!=u.getLocalData("login_data","",!1)&&""!=this.baseui.input_username.text&&""!=this.baseui.input_passward.text,';
if (source.includes(ssoAutoLoginExpression + legacyAutoLoginState)) {
  replaceOnce(
    "preserve Sakura SSO over legacy login cache",
    ssoAutoLoginExpression + legacyAutoLoginState,
    ssoAutoLoginExpression,
  );
}
const legacySakuraAutoLogin =
  "this._sakuraAutoLogin&&T.once(500,this,this.onBtnLogin)";
const sakuraSdkAutoLogin =
  "this._sakuraAutoLogin&&T.once(500,this,(()=>v.checkNeedSDKLogin(!0)))";
if (source.includes(legacySakuraAutoLogin)) {
  replaceOnce("Sakura SDK login callback", legacySakuraAutoLogin, sakuraSdkAutoLogin);
} else if (!source.includes(sakuraSdkAutoLogin)) {
  const marker = "this._sakuraAutoLogin=";
  const markerIndex = source.indexOf(marker);
  const methodEnd = markerIndex < 0 ? -1 : source.indexOf("}onNoticeReceive", markerIndex);
  if (methodEnd < 0) {
    throw new Error("Sakura SDK login callback: LoginPanel baseline not found");
  }
  source = source.slice(0, methodEnd) + "," + sakuraSdkAutoLogin + source.slice(methodEnd);
}

const autoEnterBefore =
  'this.baseui.c3.selectedIndex=this._curSelectServerData.status,this.baseui.lbl_servername.text=this._curSelectServerData.name):b.logSDK';
if (source.includes(autoEnterBefore)) {
  replaceOnce(
    "auto enter last server",
    autoEnterBefore,
    'this.baseui.c3.selectedIndex=this._curSelectServerData.status,this.baseui.lbl_servername.text=this._curSelectServerData.name,this._sakuraAutoLogin&&(this._sakuraAutoLogin=!1,T.once(50,this,this.onEnterTap))):b.logSDK',
  );
} else if (!source.includes("this._sakuraAutoLogin&&(this._sakuraAutoLogin=!1")) {
  throw new Error("auto enter last server: expected an unpatched or repaired baseline");
}

replaceOnce(
  "route Sakura payments to the novel app",
  'static openPayUrl(t){""!=t&&t&&(a.platform!=a.Platform.MOBILE_BROWSER&&a.platform!=a.Platform.DESKTOP_BROWSER||window.open(t),a.platform==a.Platform.ANDROID&&L.callNative("openPayUrl",{url:t}),a.platform==a.Platform.IOS&&r.reflection.callStaticMethod("ViewController","openExternalBrowser:",t))}',
  'static openPayUrl(t,e){if(window.SakuraBridge&&L.sakuraSession)return void window.SakuraBridge.openPayment(L,t,e);""!=t&&t&&(a.platform!=a.Platform.MOBILE_BROWSER&&a.platform!=a.Platform.DESKTOP_BROWSER||window.open(t),a.platform==a.Platform.ANDROID&&L.callNative("openPayUrl",{url:t}),a.platform==a.Platform.IOS&&r.reflection.callStaticMethod("ViewController","openExternalBrowser:",t))}',
);

source = patchManagedSsoFlow(source);
source = patchSakuraPaymentUi(source);
source = bypassDeadLegacyHotUpdate(source);

if (source.includes("root.SakuraBridge")) {
  throw new Error("Sakura bridge is already present in the target");
}
source += "\n;\n" + bridgeSource + "\n";

fs.writeFileSync(target, source, "utf8");
