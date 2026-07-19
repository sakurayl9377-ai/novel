import { describe, expect, it } from 'vitest';

import { proxyGroupLabel, proxyNodeState, proxyNodeTone, proxyServiceTone } from './proxy';

describe('proxy workbench helpers', () => {
  it('keeps service states actionable', () => {
    expect(proxyServiceTone(true, true)).toBe('success');
    expect(proxyServiceTone(true, false)).toBe('warning');
    expect(proxyServiceTone(false, false)).toBe('danger');
  });

  it('labels strategy groups and node health consistently', () => {
    expect(proxyGroupLabel({ name: 'NODE-MANUAL', type: 'Selector', current: '', options: [] })).toBe('手动节点');
    expect(proxyNodeTone({ name: 'A', type: 'VLESS', alive: true, delay: 120 })).toBe('success');
    expect(proxyNodeState({ name: 'B', type: 'VLESS', alive: false, delay: 0 })).toBe('不可用');
  });
});
