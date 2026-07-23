import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

function assertOnce(source, label, value) {
  const first = source.indexOf(value);
  const second = first < 0 ? -1 : source.indexOf(value, first + value.length);
  if (first < 0 || second >= 0) {
    throw new Error(`${label}: expected exactly one match`);
  }
}

function replaceOnce(source, label, before, after) {
  assertOnce(source, label, before);
  return source.replace(before, after);
}

export function patchSakuraPaymentUi(input) {
  assertOnce(
    input,
    "preserve RMB price formatting",
    'static fromatPayPrice(t){let e="",a=(t/n.aaa.sConfigDataPool.getLine("164").parameter[0][0]).toFixed(2),o=n.aaa.sPlatformDataPool.getLine(d.operation_plat);if(null==o)return"\uffe5 "+a;switch(a=a.replace(".00",""),o.money_type){case 1:e="\uffe5 "+a;break;case 2:default:e="$ "+a}return e}',
  );
  assertOnce(
    input,
    "preserve both original payment choices",
    "addListeners(){i.on(this.btnClose,this,this.onBtnCloseTap),i.on(this.btnLeft,this,this.onBtnCloseTap),i.on(this.baseui.btn_weixin,this,this.onWeixinPay),i.on(this.baseui.btn_alipay,this,this.onAlipayPay)}",
  );
  assertOnce(
    input,
    "preserve RMB payment amount",
    'beforeAdd(t){this._data=t;var e=s.myStoreDataPool.getPriceByShopID(this._data.shopId)-this._data.use_item;this.money_text.text="\u652f\u4ed8\u91d1\u989d:"+e+"\u5143"}',
  );
  assertOnce(
    input,
    "preserve both original payment actions",
    "onWeixinPay(){h.dump(this._data),this._data.useItem?n.reqStorePay(this._data.shopId,this._data.ad,this._data.ad_skip_by_item,this._data.use_item,d.WEIXIN):n.reqStoreBuy(this._data.shopId,this._data.buyNum,this._data.ad,this._data.sel_item,d.WEIXIN)}onAlipayPay(){this._data.useItem?n.reqStorePay(this._data.shopId,this._data.ad,this._data.ad_skip_by_item,this._data.use_item,d.ALIPAY):n.reqStoreBuy(this._data.shopId,this._data.buyNum,this._data.ad,this._data.sel_item,d.ALIPAY)}",
  );

  let source = replaceOnce(
    input,
    "close and clean up the active payment panel",
    "removeListeners(){i.off(this.btnClose,this,this.onBtnCloseTap),i.off(this.btnLeft,this,this.onBtnCloseTap)}",
    "removeListeners(){i.off(this.btnClose,this,this.onBtnCloseTap),i.off(this.btnLeft,this,this.onBtnCloseTap),i.off(this.baseui.btn_weixin,this,this.onWeixinPay),i.off(this.baseui.btn_alipay,this,this.onAlipayPay),window.SakuraPaymentPanel===this&&(window.SakuraPaymentPanel=null)}",
  );
  source = replaceOnce(
    source,
    "publish the active payment panel",
    'beforeAdd(t){this._data=t;var e=s.myStoreDataPool.getPriceByShopID(this._data.shopId)-this._data.use_item;this.money_text.text="\u652f\u4ed8\u91d1\u989d:"+e+"\u5143"}',
    'beforeAdd(t){window.SakuraPaymentPanel=this,this._data=t;var e=s.myStoreDataPool.getPriceByShopID(this._data.shopId)-this._data.use_item;this.money_text.text="\u652f\u4ed8\u91d1\u989d:"+e+"\u5143"}',
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
    throw new Error("usage: node patch-sakura-payment-ui.mjs <index.js>");
  }
  const source = fs.readFileSync(target, "utf8");
  fs.writeFileSync(target, patchSakuraPaymentUi(source), "utf8");
}
