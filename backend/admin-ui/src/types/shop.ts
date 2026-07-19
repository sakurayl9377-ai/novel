export type ShopStatus = 'inactive' | 'active' | 'archived';

export interface ShopPreset {
  value: string;
  label: string;
}

export interface ShopCatalogItem {
  type: string;
  label: string;
  equipSlot: string | null;
  presets: ShopPreset[];
}

export interface AdminShopItem {
  id: string;
  name: string;
  description: string;
  priceCoins: number;
  itemType: string;
  minLevel: number;
  assetValue: string;
  previewUrl: string;
  sortOrder: number;
  status: ShopStatus;
  revision: number;
  createdAt: string;
  updatedAt: string;
  holderCount: number;
  equipmentCount: number;
  redemptionCount: number;
  recordedRevenue: number;
  untrackedHolderCount: number;
}

export interface ShopWorkbenchResponse {
  page: number;
  pageSize: number;
  total: number;
  filters: {
    q: string;
    status: '' | ShopStatus;
    itemType: string;
  };
  stats: {
    totalItems: number;
    activeItems: number;
    inactiveItems: number;
    archivedItems: number;
    inventoryUnits: number;
    uniqueHolders: number;
    equipmentAssignments: number;
    equippedUsers: number;
    redemptionCount: number;
    recordedRevenue: number;
  };
  integrity: {
    healthy: boolean;
    untrackedHoldings: number;
    debitsWithoutInventory: number;
  };
  statusCounts: Record<ShopStatus, number>;
  typeCounts: Array<{ itemType: string; label: string; count: number }>;
  catalog: ShopCatalogItem[];
  recentRedemptions: ShopRedemption[];
  items: AdminShopItem[];
}

export interface ShopRedemption {
  id: number;
  userId: number;
  nickname: string;
  email: string;
  itemId: string;
  itemName: string;
  coins: number;
  createdAt: string;
}

export interface ShopHolder {
  userId: number;
  nickname: string;
  email: string;
  avatarUrl: string;
  status: string;
  level: number;
  acquiredAt: string;
  equipmentSlots: string[];
}

export interface ShopItemEvent {
  id: number;
  itemId: string;
  action: string;
  before: Partial<AdminShopItem>;
  after: Partial<AdminShopItem>;
  note: string;
  admin: { id: number; nickname: string; email: string };
  createdAt: string;
}

export interface ShopItemDetailResponse {
  item: AdminShopItem;
  holders: {
    page: number;
    pageSize: number;
    total: number;
    items: ShopHolder[];
  };
  events: ShopItemEvent[];
}

export interface ShopItemMutationPayload {
  name?: string;
  description?: string;
  priceCoins?: number;
  itemType?: string;
  minLevel?: number;
  assetValue?: string;
  previewUrl?: string;
  sortOrder?: number;
  expectedRevision?: number;
  changeNote?: string;
}

export interface ShopPreviewUpload {
  url: string;
  mimeType: string;
  size: number;
}
