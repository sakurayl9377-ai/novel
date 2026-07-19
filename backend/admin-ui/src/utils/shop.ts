import type {
  AdminShopItem,
  ShopCatalogItem,
  ShopItemEvent,
  ShopStatus,
} from '@/types/shop';

export function shopStatusLabel(status: ShopStatus): string {
  return ({ inactive: '草稿', active: '销售中', archived: '已归档' } as const)[status];
}

export function shopStatusTone(status: ShopStatus): 'info' | 'success' | 'warning' {
  return ({ inactive: 'warning', active: 'success', archived: 'info' } as const)[status];
}

export function shopTypeLabel(type: string, catalog: ShopCatalogItem[] = []): string {
  return catalog.find((item) => item.type === type)?.label || type || '未知类型';
}

export function shopPresetLabel(
  type: string,
  value: string,
  catalog: ShopCatalogItem[] = [],
): string {
  return catalog
    .find((item) => item.type === type)
    ?.presets.find((preset) => preset.value === value)?.label || value || '未配置';
}

export function shopEventLabel(action: string): string {
  return ({
    create: '创建草稿',
    update: '编辑商品',
    activate: '上架销售',
    deactivate: '停止销售',
    archive: '归档商品',
    restore: '恢复草稿',
  } as Record<string, string>)[action] || action;
}

export function shopStatusTransitions(status: ShopStatus): ShopStatus[] {
  if (status === 'active') return ['inactive'];
  if (status === 'inactive') return ['active', 'archived'];
  return ['inactive'];
}

export function shopStatusActionLabel(from: ShopStatus, to: ShopStatus): string {
  if (from === 'inactive' && to === 'active') return '上架销售';
  if (from === 'active' && to === 'inactive') return '停止销售';
  if (from === 'inactive' && to === 'archived') return '归档商品';
  return '恢复为草稿';
}

export function shopIdentityLocked(item: AdminShopItem | null): boolean {
  return Boolean(
    item && (item.status !== 'inactive' || item.holderCount > 0 || item.equipmentCount > 0),
  );
}

export function shopEventChanges(event: ShopItemEvent): string[] {
  const labels: Record<string, string> = {
    name: '名称',
    description: '说明',
    priceCoins: '价格',
    itemType: '类型',
    minLevel: '等级门槛',
    assetValue: '运行时预设',
    previewUrl: '预览图',
    sortOrder: '排序',
    status: '状态',
  };
  return Object.keys(labels)
    .filter((key) => event.before[key as keyof typeof event.before] !== event.after[key as keyof typeof event.after])
    .map((key) => labels[key] || key);
}
