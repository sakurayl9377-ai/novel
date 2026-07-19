import type {
  NotificationAudience,
  NotificationCategory,
  NotificationStatus,
} from '@/types/notifications';

const categoryLabels: Record<NotificationCategory, string> = {
  system: '系统通知',
  update: '版本更新',
  operation: '运营活动',
  security: '安全提醒',
  growth: '成长运营',
  race: '赛事通知',
  ai_novel: 'AI 小说',
};

const statusLabels: Record<NotificationStatus, string> = {
  draft: '草稿',
  sent: '已发送',
  canceled: '已取消',
  failed: '发送失败',
};

export function notificationCategoryLabel(category: NotificationCategory | string): string {
  return categoryLabels[category as NotificationCategory] || category || '系统通知';
}

export function notificationStatusLabel(status: NotificationStatus | string): string {
  return statusLabels[status as NotificationStatus] || status || '未知';
}

export function notificationStatusTone(status: NotificationStatus | string): 'success' | 'warning' | 'danger' | 'info' {
  if (status === 'sent') return 'success';
  if (status === 'draft') return 'info';
  if (status === 'failed') return 'danger';
  return 'warning';
}

export function notificationAudienceLabel(audience: NotificationAudience): string {
  const parts: string[] = [];
  parts.push(audience.scope === 'recent_active'
    ? `最近 ${audience.recentDays} 天活跃`
    : '全部活跃用户');
  if (audience.platforms.length) parts.push(audience.platforms.join(' / '));
  if (audience.minVersionCode || audience.maxVersionCode) {
    const min = audience.minVersionCode || '不限';
    const max = audience.maxVersionCode || '不限';
    parts.push(`版本 ${min}-${max}`);
  }
  if (audience.includeAdmins) parts.push('含管理员');
  return parts.join(' · ');
}

export function notificationAudienceShortLabel(audience: NotificationAudience): string {
  if (audience.legacy) return '历史全量记录';
  if (audience.scope === 'recent_active') return `近 ${audience.recentDays} 天活跃`;
  return audience.platforms.length ? `${audience.platforms.length} 个平台` : '全部活跃用户';
}

export function notificationActionLabel(action: string): string {
  return {
    created: '创建草稿',
    updated: '更新草稿',
    sent: '发送通知',
    canceled: '取消发送',
  }[action] || action;
}

export function notificationFormError(input: {
  title: string;
  content: string;
  changeNote: string;
  minVersionCode: number;
  maxVersionCode: number;
  scope: string;
  recentDays: number;
}): string {
  if (!input.title.trim()) return '请填写通知标题';
  if (!input.content.trim()) return '请填写通知正文';
  if (input.scope === 'recent_active' && ![1, 7, 30].includes(input.recentDays)) {
    return '请选择最近活跃时间范围';
  }
  if (input.maxVersionCode > 0 && input.minVersionCode > input.maxVersionCode) {
    return '最高版本号不能低于最低版本号';
  }
  if (input.changeNote.trim().length < 4) return '请填写具体的创建或修改原因';
  return '';
}
