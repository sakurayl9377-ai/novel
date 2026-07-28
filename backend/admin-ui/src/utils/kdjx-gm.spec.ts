import { describe, expect, it } from 'vitest';

import {
  formatYuan,
  kdjxGmActionLabel,
  kdjxGmActionResultLabel,
  kdjxGmActionResultTone,
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
    expect(kdjxGmActionResultLabel('pending')).toBe('待确认');
    expect(kdjxGmActionResultTone('pending')).toBe('warning');
  });

  it('formats payment money without inventing precision', () => {
    expect(formatYuan(600)).toBe('¥6');
    expect(formatYuan(199)).toBe('¥1.99');
    expect(formatYuan(0)).toBe('¥0');
  });
});
