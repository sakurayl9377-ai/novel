import { describe, expect, it } from 'vitest';

import type { FinanceEvent } from '@/types/finance';
import {
  financeActionLabel,
  financeEventDirection,
  financeRelatedTypeLabel,
  signedAsset,
} from './finance';

const event = (pointsDelta: number, coinsDelta: number) => ({
  pointsDelta,
  coinsDelta,
} as FinanceEvent);

describe('finance presentation helpers', () => {
  it('uses operator-facing action and source labels', () => {
    expect(financeActionLabel('shop_redeem')).toBe('商店兑换');
    expect(financeActionLabel('sso_wallet_debit')).toBe('游戏消费扣币');
    expect(financeRelatedTypeLabel('sso_wallet')).toBe('第三方游戏');
    expect(financeActionLabel('future_action')).toBe('future_action');
    expect(financeRelatedTypeLabel('admin')).toBe('管理员操作');
  });

  it('classifies credits, debits and mixed events', () => {
    expect(financeEventDirection(event(10, 0))).toBe('credit');
    expect(financeEventDirection(event(0, -5))).toBe('debit');
    expect(financeEventDirection(event(10, -5))).toBe('mixed');
    expect(financeEventDirection(event(0, 0))).toBe('zero');
  });

  it('formats signed values without adding a plus to zero', () => {
    expect(signedAsset(12)).toBe('+12');
    expect(signedAsset(-12)).toBe('-12');
    expect(signedAsset(0)).toBe('0');
  });
});
