import type {
  KdjxGmAction,
  KdjxGmActionResult,
  KdjxGmCatalogItem,
  KdjxGmDeliveryStatus,
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
  if (action === 'revoke_sessions') return '吊销游戏会话';
  if (action === 'retry_payment') return '补发支付订单';
  return '发放游戏物品';
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

export function kdjxGmDeliveryStatusLabel(
  status: KdjxGmDeliveryStatus,
): string {
  const labels: Record<KdjxGmDeliveryStatus, string> = {
    pending: '发放中',
    succeeded: '已发送',
    failed: '发送失败',
    unknown: '结果待核对',
  };
  return labels[status];
}

export function kdjxGmDeliveryStatusTone(
  status: KdjxGmDeliveryStatus,
): KdjxTagTone {
  if (status === 'succeeded') return 'success';
  if (status === 'failed') return 'danger';
  return 'warning';
}

export interface KdjxGmCatalogOption {
  value: string;
  label: string;
  item: KdjxGmCatalogItem;
}

const itemTypeLabels: Record<string, string> = {
  '0': '普通道具',
  '1': '经验药水',
  '2': '体力恢复',
  '3': '礼包',
  '4': '装备强化',
  '5': '材料',
  '6': '钥匙',
  '7': '随机礼包',
  '8': '装备觉醒',
  '9': '好感度经验',
  '10': '即开礼包',
  '15': '皮肤',
  '16': '自选礼包',
  '17': '外观与称号',
  '18': '性格道具',
};

const itemQualityLabels: Record<string, string> = {
  '0': '白色',
  '1': '白色',
  '2': '绿色',
  '3': '蓝色',
  '4': '紫色',
  '5': '橙色',
  '6': '红色',
  '7': '玫红',
};

export function kdjxGmCatalogOptions(
  items: KdjxGmCatalogItem[],
): KdjxGmCatalogOption[] {
  return items.map((item) => ({
    value: item.id,
    label: [
      item.name,
      item.description,
      kdjxGmItemMeta(item),
    ].filter(Boolean).join(' · '),
    item,
  }));
}

export function kdjxGmItemLabel(item: KdjxGmCatalogItem): string {
  return `${item.name} · ${kdjxGmItemMeta(item)}`;
}

export function kdjxGmItemMeta(item: KdjxGmCatalogItem): string {
  return [
    kdjxGmItemQualityLabel(item.quality),
    kdjxGmItemTypeLabel(item.type),
    `ID ${item.id}`,
  ].join(' · ');
}

export function kdjxGmItemTypeLabel(type: string): string {
  return itemTypeLabels[type] || `类型 ${type || '未知'}`;
}

export function kdjxGmItemQualityLabel(quality: string): string {
  return itemQualityLabels[quality] || `品质 ${quality || '未知'}`;
}

export function formatYuan(moneyCents: number): string {
  const amount = Number(moneyCents || 0) / 100;
  return Number.isInteger(amount) ? `¥${amount}` : `¥${amount.toFixed(2)}`;
}
