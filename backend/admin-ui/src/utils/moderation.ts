import type {
  CommentStatus,
  ReportItem,
  ReportStatus,
  ReportTargetType,
} from '@/types/moderation';

export function contentTargetLabel(value: string): string {
  return {
    novel: '小说',
    manga: '漫画',
    anime: '动漫',
    chapter: '章节',
    episode: '剧集',
  }[value] || value || '未知内容';
}

export function reportTargetLabel(value: string): string {
  return {
    comment: '评论',
    danmaku: '弹幕',
    chat: '聊天消息',
    user: '用户账号',
  }[value] || value || '未知目标';
}

export function commentStatusLabel(value: CommentStatus): string {
  return value === 'visible' ? '正常展示' : '已删除';
}

export function reportStatusLabel(value: ReportStatus): string {
  return {
    open: '待处理',
    resolved: '已处理',
    ignored: '已忽略',
  }[value];
}

export function reportStatusTone(
  value: ReportStatus,
): 'warning' | 'success' | 'info' {
  return {
    open: 'warning',
    resolved: 'success',
    ignored: 'info',
  }[value] as 'warning' | 'success' | 'info';
}

export function destructiveReportAction(targetType: ReportTargetType): string {
  return {
    comment: '删除评论并处理',
    danmaku: '删除弹幕并处理',
    chat: '删除消息并处理',
    user: '封禁账号并处理',
  }[targetType];
}

export function reportPreviewText(report: ReportItem): string {
  const preview = report.preview;
  if (!preview) return '目标内容已不存在';
  if (preview.type === 'user') return `${preview.nickname} · ${preview.email}`;
  return preview.content;
}
