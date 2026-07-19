import { describe, expect, it } from 'vitest';

import {
  formatRaceDuration,
  raceMetricLabel,
  raceRewardScopeLabel,
  raceSeasonEditable,
  raceSeasonStatusLabel,
  raceTierLabel,
} from '@/utils/race-operations';

describe('race operations labels', () => {
  it('maps lifecycle and metric values to operator-facing labels', () => {
    expect(raceSeasonStatusLabel('active')).toBe('进行中');
    expect(raceMetricLabel('profit')).toBe('累计正收益');
    expect(raceSeasonEditable('paused')).toBe(true);
    expect(raceSeasonEditable('active')).toBe(false);
  });

  it('formats rules and reward scopes without raw configuration text', () => {
    expect(formatRaceDuration(20)).toBe('20 秒');
    expect(formatRaceDuration(240)).toBe('4 分钟');
    expect(raceTierLabel('gold')).toBe('黄金');
    expect(raceRewardScopeLabel({ tier: 'gold', minRank: 1, maxRank: 3 }))
      .toBe('黄金 · 第 1 - 3 名');
  });
});
