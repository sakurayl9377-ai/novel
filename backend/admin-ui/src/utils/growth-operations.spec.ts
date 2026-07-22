import { describe, expect, it } from 'vitest';

import {
  campaignAudienceLabel,
  campaignEditable,
  campaignStatusLabel,
  formatRate,
  growthEventLabel,
  growthEventShortLabel,
  growthTaskSupportsContentScope,
  normalizeGrowthTaskTargetCount,
  rankingScopeLabel,
} from './growth-operations';

describe('growth operations labels', () => {
  it('turns backend keys into operational language', () => {
    expect(rankingScopeLabel('weekly_completion')).toBe('周榜 · 完读完播');
    expect(campaignStatusLabel('paused')).toBe('已暂停');
    expect(campaignAudienceLabel('active_users')).toBe('近 30 天活跃用户');
    expect(growthEventLabel('start')).toBe('开始阅读 / 播放');
    expect(growthEventLabel('login')).toBe('登录 App');
    expect(growthEventShortLabel('login')).toBe('登录');
  });

  it('locks login rewards to one claim without content filters', () => {
    expect(normalizeGrowthTaskTargetCount('login', 99)).toBe(1);
    expect(growthTaskSupportsContentScope('login')).toBe(false);
    expect(growthTaskSupportsContentScope('start')).toBe(true);
    expect(normalizeGrowthTaskTargetCount('start', 3)).toBe(3);
  });

  it('formats rates and lifecycle editability consistently', () => {
    expect(formatRate(0.125)).toBe('12.5%');
    expect(formatRate(null)).toBe('—');
    expect(campaignEditable('draft')).toBe(true);
    expect(campaignEditable('active')).toBe(false);
    expect(campaignEditable('ended')).toBe(false);
  });
});
