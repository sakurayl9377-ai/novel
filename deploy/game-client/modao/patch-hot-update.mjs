import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const legacyStartPattern =
  /start\(\)\{if\(console\.log\("Fest(?:鍦板潃|地址):"\+([A-Za-z_$][\w$]*)\.getFestUrl\(\)\),""!=\1\.getFestUrl\(\)\)\{.*?\}else this\.gotoLogin\(\)\}setProgress\(([A-Za-z_$][\w$]*)\)/gs;

function replaceOnce(source, label, before, after) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
  return source.slice(0, first) + after + source.slice(first + before.length);
}

export function enableManagedHotUpdate(source) {
  const matches = [...source.matchAll(legacyStartPattern)];
  if (matches.length !== 1) {
    throw new Error(
      `managed hot update: expected exactly one legacy start, found ${matches.length}`,
    );
  }

  const legacyStart = matches[0][0];
  const platformVariable = matches[0][1];
  const progressArgument = matches[0][2];
  const nativeMatch = legacyStart.match(
    /this\._storagePath=\(([A-Za-z_$][\w$]*)\.fileUtils\?\1\.fileUtils\.getWritablePath\(\):"\/"\)\+"asset-mote\/"/,
  );
  if (!nativeMatch) {
    throw new Error("managed hot update: native runtime variable not found");
  }
  const nativeVariable = nativeMatch[1];
  const managedStart =
    `start(){var t=this.baseui.lbl_version,e=${platformVariable}.getFestUrl();` +
    `if(t.text="Version:"+${platformVariable}.getVersionStr(),` +
    `!/^https:\\/\\/novel\\.kxhub\\.xyz\\/games\\/modao\\/hot\\/version\\.manifest$/.test(e))` +
    `return void this.gotoLogin();` +
    `this._storagePath=(${nativeVariable}.fileUtils?${nativeVariable}.fileUtils.getWritablePath():"/")+"sakura-hot/",` +
    `this.versionCompareHandle=function(t,e){${platformVariable}.setLocalVersion(t==e?t:t+"=>"+e);` +
    `for(var s=String(t).split("."),a=String(e).split("."),i=0;i<s.length;++i){` +
    `var n=parseInt(s[i]),o=parseInt(a[i]||"0");if(n!==o)return n-o}` +
    `return a.length>s.length?-1:0},` +
    `this._am=new ${nativeVariable}.AssetsManager("",this._storagePath,this.versionCompareHandle),` +
    `this._am.setVerifyCallback((function(t,e){try{` +
    `var a=Number(e&&e.size||0),i=${nativeVariable}.fileUtils.getFileSize(t);` +
    `if(a&&i!==a)return!1;return!e||!e.md5||` +
    `"function"!=typeof ${nativeVariable}.fileUtils.getMD5HashOfFile||` +
    `${nativeVariable}.fileUtils.getMD5HashOfFile(t)===e.md5}catch(t){return!1}})),` +
    `this.setProgress(0),this.armUpdateTimeout(1e4),this.hotUpdate()}` +
    `setProgress(${progressArgument})`;
  source = source.replace(legacyStartPattern, managedStart);

  const gotoMatch = source.match(
    /gotoLogin\(\)\{([A-Za-z_$][\w$]*)\.call\("Login"\)\}/g,
  );
  if (!gotoMatch || gotoMatch.length !== 1) {
    throw new Error("managed hot update: gotoLogin contract not found");
  }
  source = source.replace(
    /gotoLogin\(\)\{([A-Za-z_$][\w$]*)\.call\("Login"\)\}/,
    'gotoLogin(){this.clearUpdateTimeout&&this.clearUpdateTimeout(),$1.call("Login")}',
  );

  source = replaceOnce(
    source,
    "managed hot update controls",
    "hotUpdate(){this.checkUpdate()}",
    'clearUpdateTimeout(){this._hotUpdateTimer&&(clearTimeout(this._hotUpdateTimer),this._hotUpdateTimer=null)}' +
      'armUpdateTimeout(t){this.clearUpdateTimeout(),this._hotUpdateTimer=setTimeout((()=>{this.skipUpdate("更新服务暂时不可用，已使用当前版本")}),t)}' +
      'skipUpdate(t){this.clearUpdateTimeout(),this._am&&this._am.setEventCallback(null),this._updating=!1,this._canRetry=!1,this.baseui.lbl_msg.text=t,this.gotoLogin()}' +
      "hotUpdate(){this.checkUpdate()}",
  );
  source = replaceOnce(
    source,
    "clear manifest check timeout",
    "checkCb(t){var ",
    "checkCb(t){this.clearUpdateTimeout();var ",
  );
  source = replaceOnce(
    source,
    "arm asset update timeout",
    "startUpdate(){this._am.setEventCallback",
    "startUpdate(){this.armUpdateTimeout(12e4),this._am.setEventCallback",
  );
  source = replaceOnce(
    source,
    "refresh asset update timeout",
    "updateCb(t){var ",
    "updateCb(t){this.armUpdateTimeout(12e4);var ",
  );
  source = replaceOnce(
    source,
    "fail open after update failure",
    `case ${nativeVariable}.EventAssetsManager.UPDATE_FAILED:r.text="资源更新失败,开始重试...",this._updating=!1,this._canRetry=!0,this.retry();break;`,
    `case ${nativeVariable}.EventAssetsManager.UPDATE_FAILED:n=!0;break;`,
  );
  source = replaceOnce(
    source,
    "leave failed update for the next launch",
    "if(n&&(this._am.setEventCallback(null),this._updateListener=null,this._updating=!1),i)return",
    'if(n)return void this.skipUpdate("资源更新失败，已使用当前版本");if(i)return',
  );
  source = replaceOnce(
    source,
    "clear successful update timeout",
    "if(1==e){this.setProgress(100),",
    "if(1==e){this.clearUpdateTimeout(),this.setProgress(100),",
  );
  source = replaceOnce(
    source,
    "activate the managed update root",
    "h=this._am.getLocalManifest().getSearchPaths()",
    "h=[this._storagePath]",
  );
  source = replaceOnce(
    source,
    "persist managed update activation",
    'localStorage.setItem("HoeSeahPths",JSON.stringify(g))',
    'localStorage.setItem("SakuraHotUpdateReady","1")',
  );

  return source;
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
  fs.writeFileSync(target, enableManagedHotUpdate(source), "utf8");
}
