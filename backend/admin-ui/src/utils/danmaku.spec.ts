import { describe, expect, it } from 'vitest';

import {
  danmakuModeLabel,
  formatTimecode,
} from './danmaku';

describe('danmaku presentation rules', () => {
  it('formats playback positions without locale ambiguity', () => {
    expect(formatTimecode(0)).toBe('00:00');
    expect(formatTimecode(62_500)).toBe('01:02');
    expect(formatTimecode(3_661_000)).toBe('01:01:01');
  });

  it('uses readable labels for display modes', () => {
    expect(danmakuModeLabel('top')).toBe('顶部');
  });
});
