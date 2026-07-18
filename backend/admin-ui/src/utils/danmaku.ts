import type { DanmakuStatus } from '@/types/danmaku';

export function formatTimecode(value: unknown): string {
  const totalMs = Math.max(0, Number(value || 0));
  const totalSeconds = Math.floor(totalMs / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  const base = `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
  return hours > 0 ? `${String(hours).padStart(2, '0')}:${base}` : base;
}

export function danmakuStatusLabel(status: DanmakuStatus): string {
  return status === 'visible' ? '正常展示' : '已删除';
}

export function danmakuModeLabel(mode: string): string {
  return {
    scroll: '滚动',
    top: '顶部',
    bottom: '底部',
  }[mode] || mode || '滚动';
}
