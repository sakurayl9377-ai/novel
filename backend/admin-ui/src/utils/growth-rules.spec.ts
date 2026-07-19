import { describe, expect, it } from 'vitest';
import { reactive } from 'vue';

import type { GrowthLevelRule } from '@/types/growth-rules';
import {
  cloneGrowthRules,
  growthLevelForPoints,
  growthRuleStateLabel,
  growthRuleValidationError,
} from '@/utils/growth-rules';

const rules: GrowthLevelRule[] = Array.from({ length: 7 }, (_, index) => ({
  level: index + 1,
  points: index === 0 ? 0 : index * 100,
  name: `Level ${index + 1}`,
  effect: `Effect ${index + 1}`,
  dailyPointCap: 60 + index * 10,
  targetDays: index * 7,
  permissions: [],
}));

describe('growth rule helpers', () => {
  it('clones reactive rules into an independent editable value', () => {
    const source = reactive(rules);
    const clone = cloneGrowthRules(source);

    clone[1].points = 520;
    clone[1].permissions.push('QA permission');

    expect(source[1].points).toBe(100);
    expect(source[1].permissions).toEqual([]);
  });

  it('resolves the highest threshold reached', () => {
    expect(growthLevelForPoints(rules, 0).level).toBe(1);
    expect(growthLevelForPoints(rules, 399).level).toBe(4);
    expect(growthLevelForPoints(rules, 9999).level).toBe(7);
  });

  it('rejects thresholds and caps that move backwards', () => {
    const badThresholds = structuredClone(rules);
    badThresholds[2].points = badThresholds[1].points;
    expect(growthRuleValidationError(badThresholds)).toContain('必须高于');

    const badCaps = structuredClone(rules);
    badCaps[3].dailyPointCap = 1;
    expect(growthRuleValidationError(badCaps)).toContain('不能低于');
  });

  it('uses explicit labels for persisted states', () => {
    expect(growthRuleStateLabel('published')).toBe('当前发布');
    expect(growthRuleStateLabel('discarded')).toBe('已放弃草稿');
  });
});
