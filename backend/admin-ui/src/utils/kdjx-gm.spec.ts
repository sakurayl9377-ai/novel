import { describe, expect, it } from 'vitest';

import {
  formatYuan,
  kdjxGmCatalogOptions,
  kdjxGmActionLabel,
  kdjxGmActionResultLabel,
  kdjxGmActionResultTone,
  kdjxGmDeliveryStatusLabel,
  kdjxGmDeliveryStatusTone,
  kdjxGmItemLabel,
  kdjxGmItemQualityLabel,
  kdjxGmItemTypeLabel,
  kdjxPaymentStatusLabel,
  kdjxPaymentStatusTone,
  kdjxSessionStatusLabel,
  kdjxUserStatusLabel,
} from './kdjx-gm';

describe('KDJX GM presentation helpers', () => {
  it('describes payment and account states for operators', () => {
    expect(kdjxUserStatusLabel('banned')).toBe('已封禁');
    expect(kdjxPaymentStatusLabel('delivery_failed')).toBe('投递失败');
    expect(kdjxPaymentStatusTone('delivery_failed')).toBe('danger');
    expect(kdjxPaymentStatusTone('fulfilled')).toBe('success');
    expect(kdjxSessionStatusLabel('revoked')).toBe('已吊销');
    expect(kdjxGmActionLabel('retry_payment')).toBe('补发支付订单');
    expect(kdjxGmActionLabel('deliver_item')).toBe('发放游戏物品');
    expect(kdjxGmActionResultLabel('pending')).toBe('待确认');
    expect(kdjxGmActionResultTone('pending')).toBe('warning');
    expect(kdjxGmDeliveryStatusLabel('unknown')).toBe('结果待核对');
    expect(kdjxGmDeliveryStatusTone('succeeded')).toBe('success');
    expect(kdjxGmDeliveryStatusTone('failed')).toBe('danger');
  });

  it('builds searchable item options without accepting free-form ids', () => {
    const item = {
      id: '1001',
      name: '测试仙剑',
      description: '活动奖励用的限定武器',
      type: '16',
      quality: '5',
      maxQuantity: 9,
      deliveryTypes: ['direct', 'mail'] as const,
    };
    expect(kdjxGmCatalogOptions([item])).toEqual([{
      value: '1001',
      label: '测试仙剑 · 活动奖励用的限定武器 · 橙色 · 自选礼包 · ID 1001',
      item,
    }]);
    expect(kdjxGmItemLabel(item)).toBe('测试仙剑 · 橙色 · 自选礼包 · ID 1001');
  });

  it('uses operator-friendly item type and quality labels with explicit fallbacks', () => {
    expect(kdjxGmItemTypeLabel('0')).toBe('普通道具');
    expect(kdjxGmItemTypeLabel('16')).toBe('自选礼包');
    expect(kdjxGmItemTypeLabel('99')).toBe('类型 99');
    expect(kdjxGmItemTypeLabel('')).toBe('类型 未知');
    expect(kdjxGmItemQualityLabel('5')).toBe('橙色');
    expect(kdjxGmItemQualityLabel('7')).toBe('玫红');
    expect(kdjxGmItemQualityLabel('99')).toBe('品质 99');
    expect(kdjxGmItemQualityLabel('')).toBe('品质 未知');
  });

  it('formats payment money without inventing precision', () => {
    expect(formatYuan(600)).toBe('¥6');
    expect(formatYuan(199)).toBe('¥1.99');
    expect(formatYuan(0)).toBe('¥0');
  });
});
