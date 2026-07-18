export function formatCompactNumber(value: unknown): string {
  const number = Number(value || 0);
  if (!Number.isFinite(number)) return '0';
  return new Intl.NumberFormat('zh-CN', { notation: 'compact', maximumFractionDigits: 1 }).format(number);
}

export function formatBytes(value: unknown): string {
  let bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (bytes >= 1024 && index < units.length - 1) {
    bytes /= 1024;
    index += 1;
  }
  return `${bytes.toFixed(index === 0 ? 0 : 1)} ${units[index]}`;
}

export const adminTimeZone = 'Asia/Shanghai';

const adminDateTimeFormatter = new Intl.DateTimeFormat('zh-CN', {
  timeZone: adminTimeZone,
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

export function parseServerTime(value: unknown): Date | null {
  if (!value) return null;
  const raw = String(value).trim().replace(' ', 'T');
  const timestamp = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(raw) ? raw : `${raw}Z`;
  const date = new Date(timestamp);
  return Number.isNaN(date.getTime()) ? null : date;
}

export function formatDateTime(value: unknown): string {
  if (!value) return '—';
  const date = parseServerTime(value);
  if (!date) return String(value);
  const parts = Object.fromEntries(
    adminDateTimeFormatter
      .formatToParts(date)
      .filter((part) => part.type !== 'literal')
      .map((part) => [part.type, part.value]),
  );
  return `${parts.month}/${parts.day} ${parts.hour}:${parts.minute}`;
}

export function formatDuration(secondsValue: unknown): string {
  const seconds = Math.max(0, Number(secondsValue || 0));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  if (days > 0) return `${days} 天 ${hours} 小时`;
  const minutes = Math.floor((seconds % 3600) / 60);
  return `${hours} 小时 ${minutes} 分钟`;
}
