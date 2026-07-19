import { describe, expect, it } from 'vitest';

import type { AnalyticsErrorGroup } from '@/types/analytics';
import {
  analyticsErrorSeverity,
  analyticsEventLabel,
  analyticsPercent,
  analyticsTrendMaximum,
} from './analytics';

const baseError: AnalyticsErrorGroup = {
  fingerprint: 'fingerprint',
  occurrences: 1,
  affectedInstalls: 1,
  fatalCount: 0,
  firstSeenAt: '',
  lastSeenAt: '',
  latestVersionCode: 1,
  type: 'Error',
  message: 'message',
  stack: '',
  screen: '',
  fatal: false,
  metadata: {},
  versionName: '',
  versionCode: 1,
  platform: 'android',
  osVersion: '',
  deviceModel: '',
  occurredAt: '',
};

describe('analytics helpers', () => {
  it('clamps rates before formatting for operators', () => {
    expect(analyticsPercent(0.9876, 2)).toBe('98.76%');
    expect(analyticsPercent(2)).toBe('100.0%');
    expect(analyticsPercent(-1)).toBe('0.0%');
  });

  it('labels known events and keeps unknown names readable', () => {
    expect(analyticsEventLabel('screen_view')).toBe('页面浏览');
    expect(analyticsEventLabel('custom_event')).toBe('custom_event');
    expect(analyticsEventLabel('')).toBe('未命名事件');
  });

  it('finds a stable scale for daily trend bars', () => {
    expect(analyticsTrendMaximum([
      { day: '2026-07-19', events: 12, activeInstalls: 4, sessions: 6, errors: 1, fatalErrors: 0 },
      { day: '2026-07-20', events: 8, activeInstalls: 20, sessions: 3, errors: 2, fatalErrors: 1 },
    ])).toBe(20);
    expect(analyticsTrendMaximum([])).toBe(1);
  });

  it('treats fatal count as fatal even when the sample flag is false', () => {
    expect(analyticsErrorSeverity({ ...baseError, fatalCount: 2 })).toBe('fatal');
    expect(analyticsErrorSeverity(baseError)).toBe('error');
  });
});
