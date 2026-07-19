import type { AnalyticsDailyPoint, AnalyticsErrorGroup } from '@/types/analytics';

export function analyticsPercent(rate: number, digits = 1): string {
  const value = Math.max(0, Math.min(1, Number(rate) || 0)) * 100;
  return `${value.toFixed(digits)}%`;
}
export function analyticsEventLabel(value: string): string {
  return ({
    screen_view: '页面浏览',
    frame_metrics: '帧率采样',
    session_start: '会话开始',
    session_end: '会话结束',
    app_open: '打开 App',
    app_background: 'App 进入后台',
    app_foreground: 'App 回到前台',
  } as Record<string, string>)[value] || value || '未命名事件';
}

export function analyticsErrorSeverity(item: AnalyticsErrorGroup): 'fatal' | 'error' {
  return item.fatal || item.fatalCount > 0 ? 'fatal' : 'error';
}

export function analyticsTrendMaximum(points: AnalyticsDailyPoint[]): number {
  return Math.max(1, ...points.map((point) => Math.max(
    point.events,
    point.activeInstalls,
    point.sessions,
    point.errors,
  )));
}
