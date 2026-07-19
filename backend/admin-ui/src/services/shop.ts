import { apiFormRequest, apiRequest, queryString } from '@/services/api';
import type {
  AdminShopItem,
  ShopItemDetailResponse,
  ShopItemMutationPayload,
  ShopPreviewUpload,
  ShopStatus,
  ShopWorkbenchResponse,
} from '@/types/shop';

export function getShopWorkbench(query: {
  q?: string;
  status?: '' | ShopStatus;
  itemType?: string;
  page?: number;
  pageSize?: number;
}): Promise<ShopWorkbenchResponse> {
  return apiRequest(`/admin/shop/workbench${queryString(query)}`);
}

export function getShopItem(
  id: string,
  query: { holderQ?: string; holderPage?: number; holderPageSize?: number } = {},
): Promise<ShopItemDetailResponse> {
  return apiRequest(`/admin/shop/items/${encodeURIComponent(id)}${queryString(query)}`);
}

export function uploadShopPreview(file: File): Promise<ShopPreviewUpload> {
  const form = new FormData();
  form.append('file', file);
  return apiFormRequest('/admin/shop/previews', form);
}

export function createShopItem(
  payload: ShopItemMutationPayload,
): Promise<{ item: AdminShopItem }> {
  return apiRequest('/admin/shop/items', { method: 'POST', body: payload });
}

export function updateShopItem(
  id: string,
  payload: ShopItemMutationPayload,
): Promise<{ item: AdminShopItem }> {
  return apiRequest(`/admin/shop/items/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: payload,
  });
}

export function changeShopItemStatus(
  id: string,
  payload: { status: ShopStatus; expectedRevision: number; note: string },
): Promise<{ item: AdminShopItem }> {
  return apiRequest(`/admin/shop/items/${encodeURIComponent(id)}/status`, {
    method: 'POST',
    body: payload,
  });
}
