import { describe, expect, it } from 'vitest';

import {
  notificationAudienceLabel,
  notificationFormError,
  notificationStatusTone,
} from '@/utils/notifications';

const audience = {
  scope: 'recent_active' as const,
  recentDays: 7,
  platforms: ['android', 'ios'],
  minVersionCode: 40,
  maxVersionCode: 50,
  includeAdmins: false,
};

describe('notification utilities', () => {
  it('describes structured audiences without manual recipient input', () => {
    expect(notificationAudienceLabel(audience)).toBe('最近 7 天活跃 · android / ios · 版本 40-50');
  });

  it('maps lifecycle states to distinct tones', () => {
    expect(notificationStatusTone('draft')).toBe('info');
    expect(notificationStatusTone('sent')).toBe('success');
    expect(notificationStatusTone('failed')).toBe('danger');
  });

  it('validates the fields that affect a real send', () => {
    expect(notificationFormError({
      title: '', content: 'body', changeNote: 'note', minVersionCode: 0,
      maxVersionCode: 0, scope: 'all_active', recentDays: 0,
    })).toBe('请填写通知标题');
    expect(notificationFormError({
      title: 'title', content: 'body', changeNote: 'note', minVersionCode: 50,
      maxVersionCode: 40, scope: 'all_active', recentDays: 0,
    })).toBe('最高版本号不能低于最低版本号');
    expect(notificationFormError({
      title: 'title', content: 'body', changeNote: 'ok', minVersionCode: 0,
      maxVersionCode: 0, scope: 'all_active', recentDays: 0,
    })).toBe('请填写具体的创建或修改原因');
  });
});
