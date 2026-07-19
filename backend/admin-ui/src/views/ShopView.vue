<script setup lang="ts">
import {
  Coin,
  EditPen,
  Filter,
  Goods,
  MoreFilled,
  Picture,
  Plus,
  Refresh,
  Search,
  ShoppingBag,
  User,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';
import { useRouter } from 'vue-router';

import MetricCard from '@/components/MetricCard.vue';
import ShopItemDetailDrawer from '@/components/shop/ShopItemDetailDrawer.vue';
import ShopItemEditorDrawer from '@/components/shop/ShopItemEditorDrawer.vue';
import ShopStatusDialog from '@/components/shop/ShopStatusDialog.vue';
import { getShopWorkbench } from '@/services/shop';
import type {
  AdminShopItem,
  ShopStatus,
  ShopWorkbenchResponse,
} from '@/types/shop';
import { formatDateTime } from '@/utils/format';
import {
  shopPresetLabel,
  shopStatusActionLabel,
  shopStatusLabel,
  shopStatusTone,
  shopStatusTransitions,
  shopTypeLabel,
} from '@/utils/shop';

const router = useRouter();
const loading = ref(false);
const initialized = ref(false);
const data = ref<ShopWorkbenchResponse>(emptyWorkbench());
const query = reactive({
  q: '',
  status: '' as '' | ShopStatus,
  itemType: '',
  page: 1,
  pageSize: 20,
});

const editorOpen = ref(false);
const editingItem = ref<AdminShopItem | null>(null);
const detailOpen = ref(false);
const detailItemId = ref('');
const detailRefreshKey = ref(0);
const statusOpen = ref(false);
const statusItem = ref<AdminShopItem | null>(null);
const initialStatus = ref<ShopStatus | null>(null);

const filterCount = computed(() => [query.q, query.status, query.itemType].filter(Boolean).length);
const integrityTone = computed(() => data.value.integrity.healthy ? 'healthy' : 'attention');

onMounted(() => void loadShop());

async function loadShop(): Promise<void> {
  loading.value = true;
  try {
    data.value = await getShopWorkbench(query);
  } catch (error) {
    ElMessage.error(errorMessage(error, '商店工作台加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function searchShop(): void {
  query.page = 1;
  void loadShop();
}

function resetFilters(): void {
  Object.assign(query, { q: '', status: '', itemType: '', page: 1 });
  void loadShop();
}

function filterByStatus(status: '' | ShopStatus): void {
  query.status = query.status === status ? '' : status;
  query.page = 1;
  void loadShop();
}

function filterByType(type: string): void {
  query.itemType = query.itemType === type ? '' : type;
  query.page = 1;
  void loadShop();
}

function changePage(page: number): void {
  query.page = page;
  void loadShop();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadShop();
}

function openCreate(): void {
  editingItem.value = null;
  editorOpen.value = true;
}

function openEdit(item: AdminShopItem): void {
  if (item.status === 'archived') {
    ElMessage.warning('归档商品需要先恢复为草稿');
    return;
  }
  editingItem.value = item;
  editorOpen.value = true;
}

function openDetail(item: AdminShopItem): void {
  detailItemId.value = item.id;
  detailOpen.value = true;
}

function openStatus(item: AdminShopItem, target: ShopStatus | null = null): void {
  statusItem.value = item;
  initialStatus.value = target;
  statusOpen.value = true;
}

function handleStatusCommand(item: AdminShopItem, command: string | number | object): void {
  openStatus(item, String(command) as ShopStatus);
}

async function afterMutation(item: AdminShopItem): Promise<void> {
  detailRefreshKey.value += 1;
  editingItem.value = item;
  statusItem.value = item;
  await loadShop();
}

async function reloadAfterConflict(): Promise<void> {
  detailRefreshKey.value += 1;
  await loadShop();
  editorOpen.value = false;
  statusOpen.value = false;
}

function viewUser(userId: number): void {
  void router.push({ name: 'users', query: { userId: String(userId) } });
}

function typeLabel(type: string): string {
  return shopTypeLabel(type, data.value.catalog);
}

function presetLabel(item: AdminShopItem): string {
  return shopPresetLabel(item.itemType, item.assetValue, data.value.catalog);
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): ShopWorkbenchResponse {
  return {
    page: 1,
    pageSize: 20,
    total: 0,
    filters: { q: '', status: '', itemType: '' },
    stats: {
      totalItems: 0,
      activeItems: 0,
      inactiveItems: 0,
      archivedItems: 0,
      inventoryUnits: 0,
      uniqueHolders: 0,
      equipmentAssignments: 0,
      equippedUsers: 0,
      redemptionCount: 0,
      recordedRevenue: 0,
    },
    integrity: { healthy: true, untrackedHoldings: 0, debitsWithoutInventory: 0 },
    statusCounts: { inactive: 0, active: 0, archived: 0 },
    typeCounts: [],
    catalog: [],
    recentRedemptions: [],
    items: [],
  };
}
</script>

<template>
  <div class="page-stack shop-page">
    <section class="shop-hero">
      <div class="hero-copy">
        <span class="eyebrow">PRODUCT OPERATIONS</span>
        <h2>商品、客户端效果和用户权益保持一致</h2>
        <p>商品图片由站内上传，运行时效果只从 App 已支持的预设中选择；停用与归档不会删除用户库存。</p>
      </div>
      <div class="hero-actions">
        <div class="integrity-state" :class="integrityTone">
          <span><ElIcon><WarningFilled v-if="!data.integrity.healthy" /><Goods v-else /></ElIcon></span>
          <div>
            <strong>{{ data.integrity.healthy ? '库存与账本一致' : '存在历史数据差异' }}</strong>
            <small v-if="data.integrity.healthy">未发现孤立库存或孤立扣款</small>
            <small v-else>{{ data.integrity.untrackedHoldings }} 份未追踪库存 · {{ data.integrity.debitsWithoutInventory }} 笔无库存扣款</small>
          </div>
        </div>
        <ElButton type="primary" :icon="Plus" @click="openCreate">创建商品</ElButton>
      </div>
    </section>

    <section class="metric-grid shop-metric-grid">
      <MetricCard label="销售中" :value="data.stats.activeItems" :icon="ShoppingBag" tone="success" hint="用户当前可兑换" />
      <MetricCard label="商品草稿" :value="data.stats.inactiveItems" :icon="EditPen" hint="未公开或已停止销售" />
      <MetricCard label="持有人" :value="data.stats.uniqueHolders" :icon="User" hint="至少拥有一件商品" />
      <MetricCard label="库存件数" :value="data.stats.inventoryUnits" :icon="Goods" hint="用户权益总量" />
      <MetricCard label="已记录兑换" :value="data.stats.redemptionCount" :icon="Refresh" hint="来自不可变账本" />
      <MetricCard label="已记录收入" :value="data.stats.recordedRevenue.toLocaleString()" :icon="Coin" hint="樱花币" />
    </section>

    <section class="shop-overview">
      <div class="status-overview">
        <header><div><h3>商品生命周期</h3><p>选择状态可快速筛选</p></div><span>{{ data.stats.totalItems }} 个商品</span></header>
        <div class="status-segments">
          <button :class="{ active: query.status === '' }" @click="filterByStatus('')"><span>全部</span><strong>{{ data.stats.totalItems }}</strong></button>
          <button :class="{ active: query.status === 'active' }" @click="filterByStatus('active')"><span>销售中</span><strong>{{ data.statusCounts.active }}</strong></button>
          <button :class="{ active: query.status === 'inactive' }" @click="filterByStatus('inactive')"><span>草稿</span><strong>{{ data.statusCounts.inactive }}</strong></button>
          <button :class="{ active: query.status === 'archived' }" @click="filterByStatus('archived')"><span>已归档</span><strong>{{ data.statusCounts.archived }}</strong></button>
        </div>
      </div>
      <div class="type-overview">
        <header><div><h3>客户端能力</h3><p>只展示当前 App 可兑现的类型</p></div></header>
        <div class="type-chips">
          <button
            v-for="item in data.typeCounts"
            :key="item.itemType"
            :class="{ active: query.itemType === item.itemType }"
            @click="filterByType(item.itemType)"
          ><span>{{ item.label }}</span><b>{{ item.count }}</b></button>
        </div>
      </div>
    </section>

    <section class="catalog-section">
      <header class="section-heading">
        <div><span>PRODUCT CATALOG</span><h3>商品目录</h3><p>{{ data.total }} 个结果，按后台排序与等级门槛排列</p></div>
        <div class="catalog-actions">
          <ElButton :icon="Refresh" circle :loading="loading" title="刷新" @click="loadShop" />
        </div>
      </header>

      <div class="filter-bar">
        <ElInput v-model="query.q" clearable :prefix-icon="Search" placeholder="名称、商品 ID、说明或预设" @keyup.enter="searchShop" @clear="searchShop" />
        <ElSelect v-model="query.status" clearable placeholder="全部状态" @change="searchShop">
          <ElOption label="销售中" value="active" />
          <ElOption label="草稿" value="inactive" />
          <ElOption label="已归档" value="archived" />
        </ElSelect>
        <ElSelect v-model="query.itemType" clearable placeholder="全部商品类型" @change="searchShop">
          <ElOption v-for="option in data.catalog" :key="option.type" :label="option.label" :value="option.type" />
        </ElSelect>
        <ElButton type="primary" :icon="Search" @click="searchShop">查询</ElButton>
        <ElButton v-if="filterCount" :icon="Filter" @click="resetFilters">清除 {{ filterCount }}</ElButton>
      </div>

      <div v-loading="loading" class="product-list">
        <article v-for="item in data.items" :key="item.id" class="product-row" :class="item.status">
          <button
            class="product-preview"
            type="button"
            :aria-label="`查看${item.name}详情`"
            @click="openDetail(item)"
          >
            <img v-if="item.previewUrl" :src="item.previewUrl" :alt="item.name" />
            <span v-else><ElIcon><Picture /></ElIcon><small>无预览</small></span>
          </button>
          <div class="product-main">
            <div class="product-title">
              <h4>{{ item.name }}</h4>
              <ElTag :type="shopStatusTone(item.status)" size="small">{{ shopStatusLabel(item.status) }}</ElTag>
              <ElTag v-if="item.untrackedHolderCount" type="warning" size="small" effect="plain">{{ item.untrackedHolderCount }} 份历史库存</ElTag>
            </div>
            <p>{{ item.description || '未填写商品说明' }}</p>
            <div class="product-labels">
              <span>{{ typeLabel(item.itemType) }}</span>
              <span>{{ presetLabel(item) }}</span>
              <code>{{ item.id }}</code>
            </div>
          </div>
          <div class="product-numbers">
            <div><span>价格</span><strong>{{ item.priceCoins.toLocaleString() }}</strong><small>樱花币</small></div>
            <div><span>门槛</span><strong>Lv.{{ item.minLevel }}</strong><small>排序 {{ item.sortOrder }}</small></div>
            <div><span>持有 / 装备</span><strong>{{ item.holderCount }} / {{ item.equipmentCount }}</strong><small>{{ item.redemptionCount }} 次已记录兑换</small></div>
            <div><span>收入</span><strong>{{ item.recordedRevenue.toLocaleString() }}</strong><small>{{ formatDateTime(item.updatedAt) }}</small></div>
          </div>
          <div class="product-actions">
            <ElTooltip content="查看持有人与变更记录" placement="top">
              <ElButton circle :icon="View" :aria-label="`查看${item.name}详情`" @click="openDetail(item)" />
            </ElTooltip>
            <ElTooltip :content="item.status === 'archived' ? '先恢复为草稿' : '编辑商品'" placement="top">
              <ElButton
                circle
                :icon="EditPen"
                :aria-label="`编辑${item.name}`"
                :disabled="item.status === 'archived'"
                @click="openEdit(item)"
              />
            </ElTooltip>
            <ElDropdown trigger="click" @command="handleStatusCommand(item, $event)">
              <ElButton circle :icon="MoreFilled" aria-label="商品状态操作" title="商品状态操作" />
              <template #dropdown>
                <ElDropdownMenu>
                  <ElDropdownItem v-for="status in shopStatusTransitions(item.status)" :key="status" :command="status">
                    {{ shopStatusActionLabel(item.status, status) }}
                  </ElDropdownItem>
                </ElDropdownMenu>
              </template>
            </ElDropdown>
          </div>
        </article>

        <ElEmpty v-if="initialized && !loading && !data.items.length" description="没有符合条件的商品">
          <ElButton v-if="filterCount" @click="resetFilters">清除筛选</ElButton>
          <ElButton v-else type="primary" :icon="Plus" @click="openCreate">创建商品草稿</ElButton>
        </ElEmpty>
      </div>

      <footer v-if="data.total" class="catalog-footer">
        <span>第 {{ data.page }} 页 · 共 {{ data.total }} 个商品</span>
        <ElPagination
          background
          layout="sizes, prev, pager, next"
          :current-page="query.page"
          :page-size="query.pageSize"
          :page-sizes="[10, 20, 50, 100]"
          :total="data.total"
          @current-change="changePage"
          @size-change="changePageSize"
        />
      </footer>
    </section>

    <section class="redemption-section">
      <header class="section-heading"><div><span>RECENT REDEMPTIONS</span><h3>最近兑换</h3><p>只显示已有不可变扣款流水的兑换</p></div></header>
      <div class="redemption-list">
        <article v-for="event in data.recentRedemptions" :key="event.id">
          <span class="redemption-icon"><ElIcon><ShoppingBag /></ElIcon></span>
          <div><strong>{{ event.nickname }}</strong><span>{{ event.itemName || event.itemId }}</span></div>
          <button type="button" @click="viewUser(event.userId)">UID {{ event.userId }}</button>
          <div class="redemption-value"><strong>-{{ event.coins.toLocaleString() }}</strong><small>{{ formatDateTime(event.createdAt) }}</small></div>
        </article>
        <ElEmpty v-if="!data.recentRedemptions.length" :image-size="60" description="暂无已记录兑换" />
      </div>
    </section>

    <ShopItemEditorDrawer
      v-model="editorOpen"
      :item="editingItem"
      :catalog="data.catalog"
      @saved="afterMutation"
      @reload="reloadAfterConflict"
    />
    <ShopItemDetailDrawer
      v-model="detailOpen"
      :item-id="detailItemId"
      :catalog="data.catalog"
      :refresh-key="detailRefreshKey"
      @view-user="viewUser"
    />
    <ShopStatusDialog
      v-model="statusOpen"
      :item="statusItem"
      :initial-status="initialStatus"
      @saved="afterMutation"
      @reload="reloadAfterConflict"
    />
  </div>
</template>

<style scoped>
.shop-page { gap: 18px; }
.shop-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid var(--sakura-500); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.eyebrow, .section-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 850; letter-spacing: .1em; }
.hero-copy h2 { margin: 5px 0 6px; color: var(--ink-900); font-size: 23px; line-height: 1.25; letter-spacing: 0; }
.hero-copy p { max-width: 760px; margin: 0; color: var(--ink-500); font-size: 13px; line-height: 1.6; }
.hero-actions { display: flex; align-items: center; gap: 12px; flex: 0 0 auto; }
.integrity-state { min-width: 230px; display: grid; grid-template-columns: auto minmax(0, 1fr); align-items: center; gap: 10px; padding: 10px 12px; border: 1px solid #bfe0d0; border-radius: 8px; color: #28664f; background: #f2fbf7; }
.integrity-state.attention { color: #8a5817; border-color: #efd7a9; background: #fff9ed; }
.integrity-state > span { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 7px; background: rgb(255 255 255 / 75%); }
.integrity-state > div { min-width: 0; display: grid; gap: 2px; }
.integrity-state strong { font-size: 12px; }
.integrity-state small { color: currentColor; font-size: 10px; opacity: .8; }
.shop-metric-grid { grid-template-columns: repeat(6, minmax(0, 1fr)); }
.shop-metric-grid :deep(.metric-card) { border-radius: 8px; }
.shop-overview { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, .9fr); gap: 16px; }
.status-overview, .type-overview { min-width: 0; padding: 16px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.shop-overview header { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.shop-overview h3, .section-heading h3 { margin: 0; color: var(--ink-900); font-size: 15px; letter-spacing: 0; }
.shop-overview p, .section-heading p { margin: 3px 0 0; color: var(--ink-500); font-size: 11px; }
.shop-overview header > span { color: var(--ink-500); font-size: 11px; }
.status-segments { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 7px; }
.status-segments button { min-width: 0; display: grid; gap: 4px; padding: 10px; border: 1px solid var(--line); border-radius: 7px; color: var(--ink-500); background: var(--surface-muted); text-align: left; }
.status-segments button:hover, .status-segments button.active { color: var(--sakura-600); border-color: var(--sakura-200); background: var(--sakura-50); }
.status-segments span { font-size: 11px; }
.status-segments strong { color: var(--ink-900); font-size: 18px; }
.type-chips { display: flex; flex-wrap: wrap; gap: 7px; }
.type-chips button { min-height: 34px; display: inline-flex; align-items: center; gap: 7px; padding: 6px 9px; border: 1px solid var(--line); border-radius: 7px; color: var(--ink-700); background: var(--surface-muted); }
.type-chips button:hover, .type-chips button.active { color: #356f94; border-color: #bdd6e7; background: #f2f8fc; }
.type-chips span { font-size: 11px; }
.type-chips b { min-width: 20px; height: 20px; display: grid; place-items: center; padding: 0 5px; border-radius: 6px; color: currentColor; background: white; font-size: 10px; }
.catalog-section, .redemption-section { min-width: 0; padding: 18px; border: 1px solid var(--line); border-radius: 8px; background: white; box-shadow: 0 8px 20px rgb(42 29 39 / 3%); }
.section-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
.section-heading h3 { margin-top: 3px; font-size: 17px; }
.filter-bar { display: grid; grid-template-columns: minmax(220px, 1fr) 150px 180px auto auto; gap: 8px; margin: 16px 0 12px; padding: 11px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.product-list { min-height: 180px; }
.product-row { position: relative; min-width: 0; display: grid; grid-template-columns: 92px minmax(210px, 1.25fr) minmax(390px, 1fr) auto; gap: 14px; align-items: center; padding: 13px 4px; border-bottom: 1px solid var(--line); }
.product-row::before { content: ''; position: absolute; left: -18px; top: 17px; bottom: 17px; width: 3px; border-radius: 2px; background: #4caa7f; }
.product-row.inactive::before { background: #d69b42; }
.product-row.archived::before { background: #a5a1aa; }
.product-preview { width: 92px; aspect-ratio: 4 / 3; overflow: hidden; display: block; padding: 0; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }
.product-preview img { width: 100%; height: 100%; display: block; object-fit: cover; }
.product-preview > span { width: 100%; height: 100%; display: grid; place-items: center; align-content: center; gap: 5px; color: var(--ink-500); }
.product-preview .el-icon { font-size: 22px; }
.product-preview small { font-size: 10px; }
.product-main { min-width: 0; }
.product-title { min-width: 0; display: flex; align-items: center; gap: 6px; flex-wrap: wrap; }
.product-title h4 { min-width: 0; overflow: hidden; margin: 0; color: var(--ink-900); font-size: 14px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.product-main > p { overflow: hidden; margin: 5px 0 8px; color: var(--ink-500); font-size: 11px; line-height: 1.45; text-overflow: ellipsis; white-space: nowrap; }
.product-labels { min-width: 0; display: flex; align-items: center; gap: 5px; flex-wrap: wrap; }
.product-labels span, .product-labels code { max-width: 180px; overflow: hidden; padding: 3px 6px; border-radius: 5px; color: #546a7c; background: #eef3f6; font-family: inherit; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.product-labels code { color: var(--ink-500); background: var(--surface-muted); }
.product-numbers { min-width: 0; display: grid; grid-template-columns: repeat(4, minmax(78px, 1fr)); }
.product-numbers > div { min-width: 0; display: grid; gap: 2px; padding: 3px 10px; border-left: 1px solid var(--line); }
.product-numbers span, .product-numbers small { overflow: hidden; color: var(--ink-500); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.product-numbers strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.product-actions { display: flex; gap: 5px; }
.catalog-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding-top: 15px; }
.catalog-footer > span { color: var(--ink-500); font-size: 11px; }
.redemption-section { box-shadow: none; }
.redemption-list { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); column-gap: 22px; margin-top: 10px; }
.redemption-list article { min-width: 0; display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto; gap: 10px; align-items: center; padding: 10px 1px; border-bottom: 1px solid var(--line); }
.redemption-icon { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 7px; color: #9a671c; background: #fff2dc; }
.redemption-list article > div { min-width: 0; display: grid; gap: 2px; }
.redemption-list article > div strong, .redemption-list article > div span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.redemption-list article > div strong { color: var(--ink-900); font-size: 12px; }
.redemption-list article > div span { color: var(--ink-500); font-size: 10px; }
.redemption-list article > button { padding: 3px 5px; border: 0; color: #397096; background: transparent; font-size: 9px; }
.redemption-value { text-align: right; }
.redemption-value strong { color: #ad4d4d !important; }
.redemption-value small { color: var(--ink-500); font-size: 9px; }
@media (max-width: 1280px) {
  .shop-metric-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .product-row { grid-template-columns: 86px minmax(0, 1fr) auto; }
  .product-numbers { grid-column: 2 / -1; }
  .product-actions { grid-row: 1; grid-column: 3; }
}
@media (max-width: 900px) {
  .shop-hero { align-items: flex-start; flex-direction: column; }
  .hero-actions { width: 100%; justify-content: space-between; }
  .shop-overview { grid-template-columns: 1fr; }
  .filter-bar { grid-template-columns: minmax(0, 1fr) minmax(130px, .5fr); }
  .filter-bar > :first-child { grid-column: 1 / -1; }
  .redemption-list { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  .shop-hero { padding: 17px; }
  .hero-copy h2 { font-size: 19px; }
  .hero-actions { align-items: stretch; flex-direction: column; }
  .integrity-state { min-width: 0; }
  .shop-metric-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .status-segments { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .filter-bar { grid-template-columns: 1fr; }
  .filter-bar > :first-child { grid-column: auto; }
  .product-row { grid-template-columns: 76px minmax(0, 1fr); align-items: start; }
  .product-preview { width: 76px; }
  .product-actions { grid-row: auto; grid-column: 1 / -1; justify-content: flex-end; }
  .product-numbers { grid-column: 1 / -1; grid-template-columns: repeat(2, minmax(0, 1fr)); row-gap: 9px; }
  .product-numbers > div:nth-child(odd) { border-left: 0; }
  .catalog-footer { align-items: flex-start; flex-direction: column; }
  .catalog-footer :deep(.el-pagination__sizes), .catalog-footer > span { display: none; }
  .redemption-list article { grid-template-columns: auto minmax(0, 1fr) auto; }
  .redemption-list article > button { grid-column: 2; justify-self: start; }
  .redemption-value { grid-row: 1 / span 2; grid-column: 3; }
}
</style>
