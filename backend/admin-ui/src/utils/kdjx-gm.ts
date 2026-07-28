import type {
  KdjxGmAction,
  KdjxGmActionResult,
  KdjxPaymentStatus,
  KdjxSessionStatus,
  KdjxUserStatus,
} from '@/types/kdjx-gm';

export type KdjxTagTone = 'success' | 'warning' | 'danger' | 'info';

export function kdjxUserStatusLabel(status: KdjxUserStatus): string {
  return status === 'active' ? '正常' : '已封禁';
}

export function kdjxUserStatusTone(status: KdjxUserStatus): KdjxTagTone {
  return status === 'active' ? 'success' : 'danger';
}

export function kdjxPaymentStatusLabel(status: '' | KdjxPaymentStatus): string {
  const labels: Record<KdjxPaymentStatus, string> = {
    paid: '已扣款，待投递',
    fulfilling: '投递中',
    delivery_failed: '投递失败',
    fulfilled: '已到账',
  };
  return status ? labels[status] : '无订单';
}

export function kdjxPaymentStatusTone(
  status: '' | KdjxPaymentStatus,
): KdjxTagTone {
  if (status === 'fulfilled') return 'success';
  if (status === 'delivery_failed') return 'danger';
  if (status === 'paid' || status === 'fulfilling') return 'warning';
  return 'info';
}

export function kdjxSessionStatusLabel(status: KdjxSessionStatus): string {
  return ({ active: '有效', revoked: '已吊销', expired: '已过期' } as const)[status];
}

export function kdjxSessionStatusTone(status: KdjxSessionStatus): KdjxTagTone {
  if (status === 'active') return 'success';
  if (status === 'revoked') return 'danger';
  return 'info';
}

export function kdjxGmActionLabel(action: KdjxGmAction): string {
  return action === 'revoke_sessions' ? '吊销游戏会话' : '补发支付订单';
}

export function kdjxGmActionResultLabel(result: KdjxGmActionResult): string {
  if (result === 'success') return '成功';
  if (result === 'failed') return '失败';
  return '待确认';
}

export function kdjxGmActionResultTone(
  result: KdjxGmActionResult,
): KdjxTagTone {
  if (result === 'success') return 'success';
  if (result === 'failed') return 'danger';
  return 'warning';
}

export function formatYuan(moneyCents: number): string {
  const amount = Number(moneyCents || 0) / 100;
  return Number.isInteger(amount) ? `¥${amount}` : `¥${amount.toFixed(2)}`;
}
