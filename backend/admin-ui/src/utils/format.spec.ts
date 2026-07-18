import { describe, expect, it } from 'vitest';

import {
  adminTimeZone,
  formatBytes,
  formatCompactNumber,
  formatDateTime,
  formatDuration,
  parseServerTime,
} from './format';

describe('admin formatting helpers', () => {
  it('formats storage values without exposing invalid numbers', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(Number.NaN)).toBe('0 B');
  });

  it('formats service uptime for operators', () => {
    expect(formatDuration(90061)).toBe('1 天 1 小时');
    expect(formatDuration(3660)).toBe('1 小时 1 分钟');
  });

  it('uses compact Chinese number formatting', () => {
    expect(formatCompactNumber(12500)).toMatch(/1\.3万|1\.25万/);
  });
});

describe('admin server timestamps', () => {
  it('treats timezone-less SQLite timestamps as UTC', () => {
    expect(adminTimeZone).toBe('Asia/Shanghai');
    expect(parseServerTime('2026-07-18 09:31:00')?.toISOString()).toBe('2026-07-18T09:31:00.000Z');
    expect(formatDateTime('2026-07-18 09:31:00')).toBe('07/18 17:31');
  });

  it('keeps explicit offsets from being shifted twice', () => {
    expect(formatDateTime('2026-07-18T17:31:00+08:00')).toBe('07/18 17:31');
    expect(formatDateTime('2026-07-18T09:31:00.000Z')).toBe('07/18 17:31');
  });

  it('preserves invalid values and uses the shared empty placeholder', () => {
    expect(formatDateTime('invalid')).toBe('invalid');
    expect(formatDateTime('')).toBe('—');
  });
});
