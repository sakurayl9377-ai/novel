import { describe, expect, it } from 'vitest';

import {
  campaignAudienceLabel,
  campaignEditable,
  campaignStatusLabel,
  formatRate,
  growthEventLabel,
  rankingScopeLabel,
} from './growth-operations';

describe('growth operations labels', () => {
  it('turns backend keys into operational language', () => {
    expect(rankingScopeLabel('weekly_completion')).toBe('周榜 · 完读完播');
    expect(campaignStatusLabel('paused')).toBe('已暂停');
    expect(campaignAudienceLabel('active_users')).toBe('近 30 天活跃用户');
    expect(growthEventLabel('start')).toBe('开始阅读 / 播放');
  });

  it('formats rates and lifecycle editability consistently', () => {
    expect(formatRate(0.125)).toBe('12.5%');
    expect(formatRate(null)).toBe('—');
    expect(campaignEditable('draft')).toBe(true);
    expect(campaignEditable('active')).toBe(false);
    expect(campaignEditable('ended')).toBe(false);
  });
});
