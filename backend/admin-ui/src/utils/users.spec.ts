import { describe, expect, it } from 'vitest';

import {
  maskInstallId,
  rewardActionLabel,
  signedNumber,
  userBanReasonLabel,
} from '@/utils/users';

describe('user operations labels', () => {
  it('renders structured ban and reward reasons clearly', () => {
    expect(userBanReasonLabel('spam:批量广告')).toBe('批量广告或骚扰 · 批量广告');
    expect(rewardActionLabel('admin_adjust_coins')).toBe('后台调整樱花币');
  });

  it('formats sensitive identifiers and signed deltas', () => {
    expect(maskInstallId('abcdef1234567890')).toBe('abcdef…7890');
    expect(signedNumber(120)).toBe('+120');
    expect(signedNumber(-30)).toBe('-30');
  });
});
