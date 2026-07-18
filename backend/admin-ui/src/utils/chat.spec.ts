import { describe, expect, it } from 'vitest';

import {
  chatBlockReasonLabel,
  chatKeywordMatches,
  chatMessageTypeLabel,
  chatRoomStatusLabel,
  chatViolationActionLabel,
  normalizeChatKeywordText,
} from '@/utils/chat';

describe('chat workbench labels and keyword matching', () => {
  it('maps operational statuses to clear Chinese labels', () => {
    expect(chatRoomStatusLabel('hidden')).toBe('已隐藏');
    expect(chatMessageTypeLabel('share')).toBe('内容分享');
    expect(chatViolationActionLabel('temp_ban')).toBe('已临时封禁');
    expect(chatBlockReasonLabel('admin_block:工单 #142')).toBe('管理员手动封禁 · 工单 #142');
  });

  it('matches keywords with the same normalization as the backend', () => {
    expect(normalizeChatKeywordText(' 违-禁 词！')).toBe('违禁词');
    expect(chatKeywordMatches('违禁词', 'contains', '这里有“违 禁 词”')).toBe(true);
    expect(chatKeywordMatches('违禁词', 'exact', '违-禁词')).toBe(true);
    expect(chatKeywordMatches('违禁词', 'exact', '这句包含违禁词')).toBe(false);
  });
});
