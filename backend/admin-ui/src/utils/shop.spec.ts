import { describe, expect, it } from 'vitest';

import type { AdminShopItem, ShopCatalogItem, ShopItemEvent } from '@/types/shop';
import {
  shopEventChanges,
  shopIdentityLocked,
  shopPresetLabel,
  shopStatusTransitions,
  shopTypeLabel,
} from './shop';

const catalog: ShopCatalogItem[] = [{
  type: 'chat_bubble',
  label: '聊天气泡',
  equipSlot: 'chat_bubble',
  presets: [{ value: 'night_sakura', label: '夜樱' }],
}];

describe('shop presentation helpers', () => {
  it('uses server-provided type and preset labels', () => {
    expect(shopTypeLabel('chat_bubble', catalog)).toBe('聊天气泡');
    expect(shopPresetLabel('chat_bubble', 'night_sakura', catalog)).toBe('夜樱');
  });

  it('only exposes valid lifecycle transitions', () => {
    expect(shopStatusTransitions('active')).toEqual(['inactive']);
    expect(shopStatusTransitions('inactive')).toEqual(['active', 'archived']);
    expect(shopStatusTransitions('archived')).toEqual(['inactive']);
  });

  it('locks runtime identity after sale or outside draft state', () => {
    const item = { status: 'inactive', holderCount: 0, equipmentCount: 0 } as AdminShopItem;
    expect(shopIdentityLocked(item)).toBe(false);
    expect(shopIdentityLocked({ ...item, holderCount: 1 })).toBe(true);
    expect(shopIdentityLocked({ ...item, status: 'active' })).toBe(true);
  });

  it('summarizes audited field changes', () => {
    const event = {
      before: { name: '旧名称', priceCoins: 100, status: 'inactive' },
      after: { name: '新名称', priceCoins: 120, status: 'inactive' },
    } as ShopItemEvent;
    expect(shopEventChanges(event)).toEqual(['名称', '价格']);
  });
});
