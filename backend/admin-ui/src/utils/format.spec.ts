import { describe, expect, it } from 'vitest';

import { formatBytes, formatCompactNumber, formatDuration } from './format';

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
