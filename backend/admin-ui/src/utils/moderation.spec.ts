import { describe, expect, it } from 'vitest';

import type { ReportItem } from '@/types/moderation';
import {
  destructiveReportAction,
  reportPreviewText,
  reportStatusLabel,
  reportTargetLabel,
} from './moderation';

describe('moderation presentation rules', () => {
  it('uses action language that matches the reported target', () => {
    expect(destructiveReportAction('comment')).toBe('删除评论并处理');
    expect(destructiveReportAction('user')).toBe('封禁账号并处理');
    expect(reportTargetLabel('chat')).toBe('聊天消息');
  });

  it('makes report states readable to operators', () => {
    expect(reportStatusLabel('open')).toBe('待处理');
    expect(reportStatusLabel('resolved')).toBe('已处理');
    expect(reportStatusLabel('ignored')).toBe('已忽略');
  });

  it('handles missing and user previews without exposing raw objects', () => {
    const report = {
      preview: null,
    } as ReportItem;
    expect(reportPreviewText(report)).toBe('目标内容已不存在');

    report.preview = {
      type: 'user',
      id: 9,
      nickname: '小樱',
      email: 'sakura@example.com',
      role: 'user',
      status: 'active',
      createdAt: '2026-01-01',
      lastLoginAt: null,
    };
    expect(reportPreviewText(report)).toBe('小樱 · sakura@example.com');
  });
});
