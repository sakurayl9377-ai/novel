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

export function patchSakuraPaymentUi(input) {
  let source = input;

  source = replaceOnce(
    source,
    "show all cash prices as Sakura coins",
    'static fromatPayPrice(t){let e="",a=(t/n.aaa.sConfigDataPool.getLine("164").parameter[0][0]).toFixed(2),o=n.aaa.sPlatformDataPool.getLine(d.operation_plat);if(null==o)return"\uffe5 "+a;switch(a=a.replace(".00",""),o.money_type){case 1:e="\uffe5 "+a;break;case 2:default:e="$ "+a}return e}',
    'static fromatPayPrice(t){let e=Number(t)/Number(n.aaa.sConfigDataPool.getLine("164").parameter[0][0]);return Number.isFinite(e)?Math.round(10*e)+" \\u6a31\\u82b1\\u5e01":"-- \\u6a31\\u82b1\\u5e01"}',
  );

  source = replaceOnce(
    source,
    "use one Sakura payment button",
    "addListeners(){i.on(this.btnClose,this,this.onBtnCloseTap),i.on(this.btnLeft,this,this.onBtnCloseTap),i.on(this.baseui.btn_weixin,this,this.onWeixinPay),i.on(this.baseui.btn_alipay,this,this.onAlipayPay)}",
    "addListeners(){i.on(this.btnClose,this,this.onBtnCloseTap),i.on(this.btnLeft,this,this.onBtnCloseTap),i.on(this.baseui.btn_alipay,this,this.onAlipayPay)}",
  );

  source = replaceOnce(
    source,
    "remove Sakura payment listener",
    "removeListeners(){i.off(this.btnClose,this,this.onBtnCloseTap),i.off(this.btnLeft,this,this.onBtnCloseTap)}",
    "removeListeners(){i.off(this.btnClose,this,this.onBtnCloseTap),i.off(this.btnLeft,this,this.onBtnCloseTap),i.off(this.baseui.btn_alipay,this,this.onAlipayPay)}",
  );

  source = replaceOnce(
    source,
    "label Sakura payment amount and channel",
    'beforeAdd(t){this._data=t;var e=s.myStoreDataPool.getPriceByShopID(this._data.shopId)-this._data.use_item;this.money_text.text="\u652f\u4ed8\u91d1\u989d:"+e+"\u5143"}',
    'beforeAdd(t){this._data=t;var e=s.myStoreDataPool.getPriceByShopID(this._data.shopId)-this._data.use_item,a=this.baseui.btn_alipay;a.x=(this.baseui.btn_weixin.x+a.x)/2,this.money_text.text="\\u9700\\u652f\\u4ed8\\uff1a"+Math.round(10*e)+" \\u6a31\\u82b1\\u5e01",this.baseui.btn_weixin.visible=!1,a.visible=!0,a.title="\\u6a31\\u82b1\\u5e01\\u652f\\u4ed8",a.icon=""}',
  );

  source = replaceOnce(
    source,
    "remove the legacy WeChat payment action",
    "onWeixinPay(){h.dump(this._data),this._data.useItem?n.reqStorePay(this._data.shopId,this._data.ad,this._data.ad_skip_by_item,this._data.use_item,d.WEIXIN):n.reqStoreBuy(this._data.shopId,this._data.buyNum,this._data.ad,this._data.sel_item,d.WEIXIN)}onAlipayPay(){this._data.useItem?n.reqStorePay(this._data.shopId,this._data.ad,this._data.ad_skip_by_item,this._data.use_item,d.ALIPAY):n.reqStoreBuy(this._data.shopId,this._data.buyNum,this._data.ad,this._data.sel_item,d.ALIPAY)}",
    "onAlipayPay(){h.dump(this._data),this._data.useItem?n.reqStorePay(this._data.shopId,this._data.ad,this._data.ad_skip_by_item,this._data.use_item,d.ALIPAY):n.reqStoreBuy(this._data.shopId,this._data.buyNum,this._data.ad,this._data.sel_item,d.ALIPAY)}",
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
