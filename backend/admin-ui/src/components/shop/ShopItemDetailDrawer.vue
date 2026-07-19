<script setup lang="ts">
import {
  DocumentChecked,
  Goods,
  Lock,
  Refresh,
  Search,
  User,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { getShopItem } from '@/services/shop';
import type { ShopCatalogItem, ShopItemDetailResponse } from '@/types/shop';
import { formatDateTime } from '@/utils/format';
import {
  shopEventChanges,
  shopEventLabel,
  shopPresetLabel,
  shopStatusLabel,
  shopStatusTone,
  shopTypeLabel,
} from '@/utils/shop';

const props = defineProps<{
  modelValue: boolean;
  itemId: string;
  catalog: ShopCatalogItem[];
  refreshKey?: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'view-user': [userId: number];
}>();

const loading = ref(false);
const detail = ref<ShopItemDetailResponse | null>(null);
const activeTab = ref('overview');
const holderQ = ref('');
const holderPage = ref(1);
const holderPageSize = ref(10);

const item = computed(() => detail.value?.item || null);

watch(
  () => [props.modelValue, props.itemId, props.refreshKey] as const,
  ([open]) => {
    if (open && props.itemId) {
      holderPage.value = 1;
      void loadDetail();
    }
  },
);

async function loadDetail(): Promise<void> {
  if (!props.itemId) return;
  loading.value = true;
  try {
    detail.value = await getShopItem(props.itemId, {
      holderQ: holderQ.value.trim(),
      holderPage: holderPage.value,
      holderPageSize: holderPageSize.value,
    });
  } catch (error) {
    ElMessage.error(errorMessage(error, '商品详情加载失败'));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

function searchHolders(): void {
  holderPage.value = 1;
  void loadDetail();
}

function changeHolderPage(page: number): void {
  holderPage.value = page;
  void loadDetail();
}

function viewUser(userId: number): void {
  emit('update:modelValue', false);
  emit('view-user', userId);
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(860px, 97vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="detail-heading">
        <img v-if="item?.previewUrl" :src="item.previewUrl" alt="商品预览" />
        <span v-else class="heading-placeholder"><ElIcon><Goods /></ElIcon></span>
        <div>
          <span>PRODUCT RECORD</span>
          <h2>{{ item?.name || '商品详情' }}</h2>
          <p v-if="item">{{ item.id }} · 配置版本 {{ item.revision }}</p>
        </div>
        <ElTag v-if="item" :type="shopStatusTone(item.status)" effect="light">{{ shopStatusLabel(item.status) }}</ElTag>
      </div>
    </template>

    <div v-loading="loading" class="detail-body">
      <template v-if="detail && item">
        <ElAlert
          v-if="item.untrackedHolderCount"
          :title="`${item.untrackedHolderCount} 份历史库存没有对应兑换流水`"
          description="这是旧版本未记录完整交易造成的存量差异，后台不会自动补写或删除用户权益。"
          type="warning"
          :closable="false"
          show-icon
        />

        <section class="detail-metrics">
          <div><span>持有人</span><strong>{{ item.holderCount }}</strong><small>{{ item.equipmentCount }} 个装备位正在使用</small></div>
          <div><span>已记录兑换</span><strong>{{ item.redemptionCount }}</strong><small>仅统计不可变账本</small></div>
          <div><span>已记录收入</span><strong>{{ item.recordedRevenue.toLocaleString() }}</strong><small>樱花币</small></div>
          <div><span>当前价格</span><strong>{{ item.priceCoins.toLocaleString() }}</strong><small>Lv.{{ item.minLevel }} 起可兑换</small></div>
        </section>

        <ElTabs v-model="activeTab" class="detail-tabs">
          <ElTabPane name="overview" label="商品配置">
            <section class="product-overview">
              <div class="large-preview">
                <img v-if="item.previewUrl" :src="item.previewUrl" alt="商品预览" />
                <span v-else><ElIcon><Goods /></ElIcon>没有预览图</span>
              </div>
              <dl>
                <div><dt>商品类型</dt><dd>{{ shopTypeLabel(item.itemType, catalog) }}</dd></div>
                <div><dt>运行时预设</dt><dd>{{ shopPresetLabel(item.itemType, item.assetValue, catalog) }}</dd></div>
                <div><dt>商店排序</dt><dd>{{ item.sortOrder }}</dd></div>
                <div><dt>创建时间</dt><dd>{{ formatDateTime(item.createdAt) }}</dd></div>
                <div><dt>最近修改</dt><dd>{{ formatDateTime(item.updatedAt) }}</dd></div>
                <div class="wide"><dt>商品说明</dt><dd>{{ item.description || '未填写' }}</dd></div>
              </dl>
            </section>
            <section class="ownership-policy">
              <span><ElIcon><Lock /></ElIcon></span>
              <div><strong>停用或归档不会回收用户权益</strong><p>已有持有人可以继续使用该商品；类型与运行时预设在存在持有人后永久锁定。</p></div>
            </section>
          </ElTabPane>

          <ElTabPane name="holders" :label="`持有人 ${detail.holders.total}`">
            <div class="holder-toolbar">
              <ElInput v-model="holderQ" clearable placeholder="昵称、邮箱或 UID" :prefix-icon="Search" @keyup.enter="searchHolders" @clear="searchHolders" />
              <ElButton :icon="Refresh" @click="searchHolders">查询</ElButton>
            </div>
            <div class="holder-list">
              <article v-for="holder in detail.holders.items" :key="holder.userId">
                <ElAvatar :src="holder.avatarUrl">{{ holder.nickname.slice(0, 1) }}</ElAvatar>
                <div class="holder-main"><strong>{{ holder.nickname }}</strong><span>{{ holder.email }} · UID {{ holder.userId }}</span></div>
                <div class="holder-state">
                  <ElTag size="small" effect="plain">Lv.{{ holder.level }}</ElTag>
                  <ElTag v-if="holder.equipmentSlots.length" size="small" type="success">正在装备</ElTag>
                  <small>{{ formatDateTime(holder.acquiredAt) }}</small>
                </div>
                <ElTooltip content="打开用户工作台" placement="top">
                  <ElButton
                    circle
                    :icon="User"
                    :aria-label="`打开${holder.nickname}的用户工作台`"
                    @click="viewUser(holder.userId)"
                  />
                </ElTooltip>
              </article>
              <ElEmpty v-if="!detail.holders.items.length" :image-size="64" description="没有符合条件的持有人" />
            </div>
            <ElPagination
              v-if="detail.holders.total > holderPageSize"
              class="holder-pagination"
              background
              layout="prev, pager, next"
              :current-page="holderPage"
              :page-size="holderPageSize"
              :total="detail.holders.total"
              @current-change="changeHolderPage"
            />
          </ElTabPane>

          <ElTabPane name="events" :label="`变更记录 ${detail.events.length}`">
            <div class="event-list">
              <article v-for="event in detail.events" :key="event.id">
                <span class="event-icon" :class="event.action"><ElIcon><DocumentChecked /></ElIcon></span>
                <div class="event-main">
                  <div><strong>{{ shopEventLabel(event.action) }}</strong><ElTag v-for="field in shopEventChanges(event)" :key="field" size="small" effect="plain">{{ field }}</ElTag></div>
                  <p>{{ event.note || '未填写操作说明' }}</p>
                  <span>{{ event.admin.nickname || event.admin.email }} · {{ formatDateTime(event.createdAt) }}</span>
                </div>
              </article>
              <ElEmpty v-if="!detail.events.length" :image-size="64" description="暂无商品变更记录" />
            </div>
          </ElTabPane>
        </ElTabs>
      </template>
      <ElEmpty v-else-if="!loading" description="商品不存在或已无法读取" />
    </div>
  </ElDrawer>
</template>

<style scoped>
.detail-heading { width: 100%; display: flex; align-items: center; gap: 12px; min-width: 0; }
.detail-heading > img, .heading-placeholder { width: 50px; height: 50px; flex: 0 0 50px; border-radius: 7px; object-fit: cover; }
.heading-placeholder { display: grid; place-items: center; color: var(--sakura-600); background: var(--sakura-50); font-size: 22px; }
.detail-heading > div { min-width: 0; flex: 1; }
.detail-heading div > span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .08em; }
.detail-heading h2 { overflow: hidden; margin: 4px 0 2px; color: var(--ink-900); font-size: 19px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.detail-heading p { overflow: hidden; margin: 0; color: var(--ink-500); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.detail-body { min-height: 360px; display: grid; align-content: start; gap: 14px; }
.detail-metrics { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; }
.detail-metrics > div { min-width: 0; display: grid; gap: 4px; padding: 14px; border-right: 1px solid var(--line); }
.detail-metrics > div:last-child { border-right: 0; }
.detail-metrics span, .detail-metrics small { color: var(--ink-500); font-size: 11px; }
.detail-metrics strong { color: var(--ink-900); font-size: 22px; letter-spacing: 0; }
.product-overview { display: grid; grid-template-columns: 230px minmax(0, 1fr); gap: 20px; padding: 10px 0; }
.large-preview { width: 100%; aspect-ratio: 4 / 3; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.large-preview img { width: 100%; height: 100%; display: block; object-fit: cover; }
.large-preview > span { width: 100%; height: 100%; display: grid; place-items: center; align-content: center; gap: 8px; color: var(--ink-500); font-size: 12px; }
.large-preview .el-icon { font-size: 28px; }
.product-overview dl { margin: 0; display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.product-overview dl > div { min-width: 0; padding: 11px 12px; border-bottom: 1px solid var(--line); }
.product-overview dl .wide { grid-column: 1 / -1; }
.product-overview dt { color: var(--ink-500); font-size: 11px; }
.product-overview dd { margin: 5px 0 0; color: var(--ink-900); font-size: 13px; line-height: 1.5; overflow-wrap: anywhere; }
.ownership-policy { display: flex; align-items: center; gap: 12px; margin-top: 8px; padding: 13px 14px; border: 1px solid #cfe1ee; border-radius: 8px; background: #f4f9fc; }
.ownership-policy > span { width: 34px; height: 34px; flex: 0 0 34px; display: grid; place-items: center; border-radius: 7px; color: #356e95; background: #e1eff8; }
.ownership-policy strong { color: #285978; font-size: 13px; }
.ownership-policy p { margin: 3px 0 0; color: #587486; font-size: 11px; line-height: 1.5; }
.holder-toolbar { display: flex; gap: 8px; margin: 10px 0 12px; }
.holder-toolbar .el-input { max-width: 360px; }
.holder-list { display: grid; }
.holder-list article { display: grid; grid-template-columns: auto minmax(0, 1fr) auto auto; align-items: center; gap: 11px; min-width: 0; padding: 11px 4px; border-bottom: 1px solid var(--line); }
.holder-main { min-width: 0; display: grid; gap: 3px; }
.holder-main strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.holder-main span { overflow: hidden; color: var(--ink-500); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.holder-state { display: flex; align-items: center; justify-content: flex-end; gap: 5px; flex-wrap: wrap; }
.holder-state small { width: 100%; color: var(--ink-500); font-size: 10px; text-align: right; }
.holder-pagination { justify-content: flex-end; margin-top: 16px; }
.event-list { display: grid; margin-top: 8px; }
.event-list article { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 11px; padding: 13px 2px; border-bottom: 1px solid var(--line); }
.event-icon { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 7px; color: #58697d; background: #edf1f5; }
.event-icon.activate { color: #287258; background: #e5f5ed; }
.event-icon.deactivate, .event-icon.archive { color: #9b5d1a; background: #fff1df; }
.event-main { min-width: 0; }
.event-main > div { display: flex; align-items: center; gap: 5px; flex-wrap: wrap; }
.event-main strong { margin-right: 4px; color: var(--ink-900); font-size: 13px; }
.event-main p { margin: 5px 0 4px; color: var(--ink-700); font-size: 12px; line-height: 1.5; }
.event-main > span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 700px) {
  .detail-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-metrics > div:nth-child(2) { border-right: 0; }
  .detail-metrics > div:nth-child(-n+2) { border-bottom: 1px solid var(--line); }
  .product-overview { grid-template-columns: 1fr; }
  .large-preview { max-height: 250px; }
  .holder-list article { grid-template-columns: auto minmax(0, 1fr) auto; }
  .holder-state { grid-column: 2 / -1; justify-content: flex-start; }
  .holder-state small { text-align: left; }
}
</style>
