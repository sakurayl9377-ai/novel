import assert from "node:assert/strict";

import { enableManagedHotUpdate } from "./patch-hot-update.mjs";
import { patchHotUpdateApplication } from "./prepare-hot-update.mjs";

const legacyStart =
  'start(){if(console.log("Fest鍦板潃:"+r.getFestUrl()),""!=r.getFestUrl()){' +
  'this._storagePath=(s.fileUtils?s.fileUtils.getWritablePath():"/")+"asset-mote/",' +
  'this._am=new s.AssetsManager("",this._storagePath,this.versionCompareHandle),' +
  "this.hotUpdate()}else this.gotoLogin()}setProgress(t)";
const legacyUpdater =
  "prefix " +
  'gotoLogin(){g.call("Login")}' +
  legacyStart +
  "{}" +
  "hotUpdate(){this.checkUpdate()}" +
  "checkCb(t){var e=!1}" +
  "startUpdate(){this._am.setEventCallback(this.updateCb.bind(this))}" +
  'updateCb(t){var e=!1,i=!1,n=!1,r=this.baseui.lbl_msg;case s.EventAssetsManager.UPDATE_FAILED:r.text="资源更新失败,开始重试...",this._updating=!1,this._canRetry=!0,this.retry();break;' +
  "if(n&&(this._am.setEventCallback(null),this._updateListener=null,this._updating=!1),i)return x;" +
  "if(1==e){this.setProgress(100),h=this._am.getLocalManifest().getSearchPaths()," +
  'localStorage.setItem("HoeSeahPths",JSON.stringify(g)),setTimeout((()=>{a.restart()}),1500)}} suffix';

const patched = enableManagedHotUpdate(legacyUpdater);
assert.match(
  patched,
  /novel\\\.kxhub\\\.xyz\\\/games\\\/modao\\\/hot\\\/version\\\.manifest/,
);
assert.match(patched, /new s\.AssetsManager/);
assert.match(patched, /getMD5HashOfFile/);
assert.match(patched, /armUpdateTimeout\(1e4\)/);
assert.match(patched, /armUpdateTimeout\(12e4\)/);
assert.match(patched, /SakuraHotUpdateReady/);
assert.match(patched, /h=\[this\._storagePath\]/);
assert.match(patched, /setTimeout\(\(\(\)=>\{a\.restart\(\)\}\),1500\)/);
assert.doesNotMatch(patched, /HoeSeahPths|downloadFailedAssets/);
assert.throws(
  () => enableManagedHotUpdate(patched),
  /expected exactly one legacy start, found 0/,
);
assert.throws(
  () => enableManagedHotUpdate(`${legacyUpdater}\n${legacyUpdater}`),
  /expected exactly one legacy start, found 2/,
);

const application = `class Application {
        start() {
          return cc.game.init({
            debugMode: 0
          });
        }
}`;
const patchedApplication = patchHotUpdateApplication(application);
assert.match(patchedApplication, /SakuraHotUpdateReady/);
assert.match(patchedApplication, /getWritablePath\(\) \+ 'sakura-hot\/'/);
assert.match(patchedApplication, /searchPaths\.unshift\(updateRoot\)/);
assert.throws(
  () => patchHotUpdateApplication(patchedApplication),
  /expected exactly one match/,
);

console.log("managed hot update tests passed");
