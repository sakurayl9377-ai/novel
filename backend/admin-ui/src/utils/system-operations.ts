import type { AuditItem } from '@/types/audit';
import type { ReleaseWorkbenchResponse } from '@/types/releases';
import type { VersionInstall } from '@/types/versions';

export function auditMethodLabel(value: string): string {
  return value || '未知方法';
}

export function auditMethodTone(value: string): 'info' | 'success' | 'warning' | 'danger' {
  return ({ GET: 'info', POST: 'success', PUT: 'warning', PATCH: 'warning', DELETE: 'danger' } as const)[value as 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'] || 'info';
}

export function auditStatusTone(statusCode: number): 'success' | 'danger' {
  return Number(statusCode || 0) >= 400 ? 'danger' : 'success';
}

export function auditStatusLabel(statusCode: number): string {
  return Number(statusCode || 0) >= 400 ? '失败' : '成功';
}

export function auditActorLabel(item: AuditItem): string {
  return item.admin?.nickname || item.admin?.email || '系统';
}

export function versionPlatformLabel(value: string): string {
  return ({ android: 'Android', ios: 'iOS', web: 'Web' } as Record<string, string>)[value] || value || '未知平台';
}

export function versionPlatformTone(value: string): 'success' | 'info' | 'warning' {
  return ({ android: 'success', ios: 'info', web: 'warning' } as Record<string, 'success' | 'info' | 'warning'>)[value] || 'warning';
}

export function versionInstallFreshness(item: VersionInstall): 'fresh' | 'stale' {
  const timestamp = Date.parse(item.lastSeenAt?.replace(' ', 'T') + (/[zZ]|[+-]\d{2}:?\d{2}$/.test(item.lastSeenAt || '') ? '' : 'Z'));
  return Number.isFinite(timestamp) && Date.now() - timestamp <= 30 * 86400000 ? 'fresh' : 'stale';
}

export function releaseIntegrityLabel(value: ReleaseWorkbenchResponse['integrityStatus']): string {
  return ({ unconfigured: '未配置', blocked: '不可发布', warning: '需要核对', ready: '完整性通过' } as const)[value];
}

export function releaseIntegrityTone(value: ReleaseWorkbenchResponse['integrityStatus']): 'info' | 'warning' | 'danger' | 'success' {
  return ({ unconfigured: 'info', blocked: 'danger', warning: 'warning', ready: 'success' } as const)[value];
}

export function releaseCheckLabel(value: string): string {
  return ({ ready: '正常', verified: '已校验', missing: '缺失', mismatch: '不一致', unverified: '未校验', invalid: '无效' } as Record<string, string>)[value] || value || '未知';
}
