<script setup lang="ts">
import {
  Bell,
  Check,
  EditPen,
  Filter,
  Lock,
  Plus,
  Promotion,
  Refresh,
  Search,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import NotificationDetailDrawer from '@/components/notifications/NotificationDetailDrawer.vue';
import NotificationEditorDrawer from '@/components/notifications/NotificationEditorDrawer.vue';
import NotificationSendDialog from '@/components/notifications/NotificationSendDialog.vue';
import {
  getNotification,
  getNotifications,
} from '@/services/notifications';
import type {
  NotificationCategory,
  NotificationDetailResponse,
  NotificationItem,
  NotificationOptions,
  NotificationSendResponse,
  NotificationStatus,
  NotificationStats,
  NotificationWorkbenchResponse,
} from '@/types/notifications';
import { formatCompactNumber, formatDateTime } from '@/utils/format';
import {
  notificationAudienceShortLabel,
  notificationCategoryLabel,
  notificationStatusLabel,
  notificationStatusTone,
} from '@/utils/notifications';

const loading = ref(false);
const initialized = ref(false);
const data = ref<NotificationWorkbenchResponse>(emptyWorkbench());
const query = reactive({
  q: '',
  status: '' as '' | NotificationStatus,
  category: '' as '' | NotificationCategory,
  page: 1,
  pageSize: 20,
});

const editorOpen = ref(false);
const editingItem = ref<NotificationItem | null>(null);
const detailOpen = ref(false);
const detailId = ref(0);
const detailRefreshKey = ref(0);
const sendOpen = ref(false);
const sendDetail = ref<NotificationDetailResponse | null>(null);
const preparingSend = ref(false);

const filterCount = computed(() => [query.q, query.status, query.category].filter(Boolean).length);
const statusOptions = computed(() => data.value.options.statuses.length
  ? data.value.options.statuses
  : ['draft', 'sent', 'canceled', 'failed'] as NotificationStatus[]);
const categoryOptions = computed(() => data.value.options.categories.length
  ? data.value.options.categories
  : ['system', 'update', 'operation', 'security'] as NotificationCategory[]);

onMounted(() => void loadNotifications());

async function loadNotifications(): Promise<void> {
  loading.value = true;
  try {
    data.value = await getNotifications(query);
  } catch (error) {
    ElMessage.error(errorMessage(error, '通知记录加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function searchNotifications(): void {
  query.page = 1;
  void loadNotifications();
}

function resetFilters(): void {
  Object.assign(query, { q: '', status: '', category: '', page: 1 });
  void loadNotifications();
}

function filterStatus(status: '' | NotificationStatus): void {
  query.status = query.status === status ? '' : status;
  query.page = 1;
  void loadNotifications();
}

function changePage(page: number): void {
  query.page = page;
  void loadNotifications();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadNotifications();
}

function openCreate(): void {
  editingItem.value = null;
  editorOpen.value = true;
}

function openEdit(value: unknown): void {
  const item = value as NotificationItem;
  if (!canMutate(item)) {
    ElMessage.warning('已发送或已取消的通知不能编辑');
    return;
  }
  editingItem.value = item;
  editorOpen.value = true;
  detailOpen.value = false;
}

function openDetail(value: unknown): void {
  const item = value as NotificationItem;
  detailId.value = item.id;
  detailOpen.value = true;
}

async function openSend(value: unknown): Promise<void> {
  const item = value as NotificationItem;
  if (!canMutate(item)) {
    ElMessage.warning('当前通知状态不允许发送');
    return;
  }
  preparingSend.value = true;
  try {
    sendDetail.value = await getNotification(item.id);
    sendOpen.value = true;
  } catch (error) {
    ElMessage.error(errorMessage(error, '发送确认信息加载失败'));
  } finally {
    preparingSend.value = false;
  }
}

function handleDetailEdit(item: NotificationItem): void {
  openEdit(item);
}

function handleDetailSend(detail: NotificationDetailResponse): void {
  sendDetail.value = detail;
  sendOpen.value = true;
}

async function afterSaved(detail: NotificationDetailResponse): Promise<void> {
  detailId.value = detail.item.id;
  detailRefreshKey.value += 1;
  await loadNotifications();
}

async function afterSent(result: NotificationSendResponse): Promise<void> {
  detailId.value = result.item.id;
  detailRefreshKey.value += 1;
  await loadNotifications();
}

async function afterCanceled(detail: NotificationDetailResponse): Promise<void> {
  detailRefreshKey.value += 1;
  await loadNotifications();
  if (detail.item.status === 'canceled') detailOpen.value = true;
}

function statusCount(status: NotificationStatus): number {
  if (status === 'draft') return data.value.stats.drafts;
  if (status === 'sent') return data.value.stats.sent;
  if (status === 'canceled') return data.value.stats.canceled;
  return data.value.stats.failed;
}

function canMutate(item: unknown): boolean {
  const value = item as NotificationItem;
  return value.status === 'draft' || value.status === 'failed';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyStats(): NotificationStats {
  return { total: 0, drafts: 0, sent: 0, canceled: 0, failed: 0, sent24h: 0, delivered: 0, unread: 0, sentRecords: 0 };
}

function emptyOptions(): NotificationOptions {
  return {
    statuses: [],
    categories: [],
    scopes: [],
    recentDays: [1, 7, 30],
    platforms: [],
    maxRecipients: 50000,
  };
}

function emptyWorkbench(): NotificationWorkbenchResponse {
  return { generatedAt: '', page: 1, pageSize: 20, total: 0, items: [], stats: emptyStats(), options: emptyOptions() };
}
</script>

<template>
  <div class="page-stack notification-page">
    <section class="notification-hero">
      <div class="hero-copy">
        <span class="eyebrow">IN-APP NOTIFICATION OPERATIONS</span>
        <h2>通知发布工作台</h2>
        <p>消息先保存为草稿，受众可预览、发送可追踪，用户端只接收真实写入消息中心的站内通知。</p>
      </div>
      <div class="channel-state">
        <span class="channel-icon"><ElIcon><Bell /></ElIcon></span>
        <div><strong>站内消息渠道</strong><small>不包含邮件、推送或外部 URL</small></div>
        <ElTag type="success" effect="plain"><ElIcon><Check /></ElIcon>可用</ElTag>
      </div>
    </section>

    <section class="metric-grid notification-metrics">
      <MetricCard label="待处理草稿" :value="data.stats.drafts" :icon="EditPen" hint="保存后仍不会发送" />
      <MetricCard label="24h 已发送" :value="data.stats.sent24h" :icon="Promotion" hint="按发送记录统计" tone="success" />
      <MetricCard label="累计写入消息" :value="formatCompactNumber(data.stats.delivered)" :icon="Bell" hint="原子写入用户消息中心" />
      <MetricCard label="当前未读" :value="formatCompactNumber(data.stats.unread)" :icon="WarningFilled" hint="用户端尚未读的站内消息" tone="warning" />
    </section>

    <section class="status-strip notification-status-strip">
      <button :class="{ active: !query.status }" type="button" @click="filterStatus('')"><span>全部记录</span><strong>{{ data.stats.total }}</strong></button>
      <button v-for="status in statusOptions" :key="status" :class="{ active: query.status === status }" type="button" @click="filterStatus(status)"><span>{{ notificationStatusLabel(status) }}</span><strong>{{ statusCount(status) }}</strong></button>
    </section>

    <section class="notification-list-section">
      <header class="section-heading">
        <div><span>MESSAGE HISTORY</span><h3>发布记录</h3><p>{{ data.total }} 条记录 · 发送和取消都会保留事件原因</p></div>
        <div class="section-actions"><ElButton :icon="Refresh" circle :loading="loading" title="刷新" @click="loadNotifications" /><ElButton type="primary" :icon="Plus" @click="openCreate">创建通知草稿</ElButton></div>
      </header>

      <div class="filter-bar notification-filter-bar">
        <ElInput v-model="query.q" clearable :prefix-icon="Search" placeholder="搜索标题、正文或操作人" @keyup.enter="searchNotifications" @clear="searchNotifications" />
        <ElSelect v-model="query.status" clearable placeholder="全部状态" @change="searchNotifications"><ElOption v-for="status in statusOptions" :key="status" :label="notificationStatusLabel(status)" :value="status" /></ElSelect>
        <ElSelect v-model="query.category" clearable placeholder="全部类型" @change="searchNotifications"><ElOption v-for="category in categoryOptions" :key="category" :label="notificationCategoryLabel(category)" :value="category" /></ElSelect>
        <ElButton type="primary" :icon="Search" @click="searchNotifications">查询</ElButton>
        <ElButton v-if="filterCount" :icon="Filter" @click="resetFilters">清除 {{ filterCount }}</ElButton>
      </div>

      <div v-loading="loading" class="notification-table-wrap">
        <ElTable :data="data.items" row-key="id" empty-text="没有符合条件的通知记录" @row-dblclick="openDetail">
          <ElTableColumn label="通知" min-width="300">
            <template #default="{ row }">
              <div class="notification-cell"><span class="notification-cell-icon"><ElIcon><Bell /></ElIcon></span><div><strong>{{ row.title }}</strong><small>{{ notificationCategoryLabel(row.category) }} · 修订号 {{ row.revision }}</small><p>{{ row.content }}</p></div></div>
            </template>
          </ElTableColumn>
          <ElTableColumn label="状态" width="100"><template #default="{ row }"><ElTag :type="notificationStatusTone(row.status)" effect="plain">{{ notificationStatusLabel(row.status) }}</ElTag></template></ElTableColumn>
          <ElTableColumn label="受众" min-width="180"><template #default="{ row }"><div class="audience-cell"><strong>{{ row.status === 'draft' ? (row.previewCount || '待预览') : `${row.recipientCount.toLocaleString()} 位` }}</strong><small>{{ notificationAudienceShortLabel(row.audience) }}</small></div></template></ElTableColumn>
          <ElTableColumn label="发送结果" min-width="145"><template #default="{ row }"><div class="delivery-cell"><strong>{{ row.deliveredCount.toLocaleString() }} 条</strong><small v-if="row.status === 'sent'">未读 {{ row.unreadCount.toLocaleString() }}</small><small v-else>{{ row.failureReason || '尚未发送' }}</small></div></template></ElTableColumn>
          <ElTableColumn label="时间" width="145"><template #default="{ row }"><span>{{ formatDateTime(row.sentAt || row.updatedAt || row.createdAt) }}</span><small class="table-subline">{{ row.operator?.nickname || '系统' }}</small></template></ElTableColumn>
          <ElTableColumn label="操作" width="145">
            <template #default="{ row }">
              <div class="row-actions">
                <ElTooltip content="查看详情"><ElButton circle :icon="View" :aria-label="`查看${row.title}详情`" @click.stop="openDetail(row)" /></ElTooltip>
                <ElTooltip content="编辑草稿"><ElButton circle :icon="EditPen" :disabled="!canMutate(row)" :aria-label="`编辑${row.title}`" @click.stop="openEdit(row)" /></ElTooltip>
                <ElTooltip content="发送通知"><ElButton circle type="primary" plain :icon="Promotion" :loading="preparingSend" :disabled="!canMutate(row)" :aria-label="`发送${row.title}`" @click.stop="openSend(row)" /></ElTooltip>
              </div>
            </template>
          </ElTableColumn>
        </ElTable>
        <ElEmpty v-if="initialized && !loading && !data.items.length" :image-size="66" description="没有符合条件的通知记录"><ElButton v-if="filterCount" @click="resetFilters">清除筛选</ElButton><ElButton v-else type="primary" :icon="Plus" @click="openCreate">创建第一条草稿</ElButton></ElEmpty>
      </div>

      <footer v-if="data.total" class="table-footer"><span>第 {{ data.page }} 页 · 共 {{ data.total }} 条记录</span><ElPagination background layout="sizes, prev, pager, next" :current-page="query.page" :page-size="query.pageSize" :page-sizes="[10, 20, 50, 100]" :total="data.total" @current-change="changePage" @size-change="changePageSize" /></footer>
    </section>

    <section class="notification-boundary">
      <div><ElIcon><Lock /></ElIcon><div><strong>渠道边界</strong><span>当前后台只负责站内消息。邮件、系统推送和外部链接没有接入，不会在界面上伪装成“已发送”。</span></div></div>
      <ElTag type="info" effect="plain">发送上限 {{ data.options.maxRecipients.toLocaleString() }} 位</ElTag>
    </section>

    <NotificationEditorDrawer v-model="editorOpen" :item="editingItem" :options="data.options" @saved="afterSaved" @reload="loadNotifications" />
    <NotificationDetailDrawer v-model="detailOpen" :notification-id="detailId" :refresh-key="detailRefreshKey" @edit="handleDetailEdit" @send="handleDetailSend" @canceled="afterCanceled" />
    <NotificationSendDialog v-model="sendOpen" :detail="sendDetail" @sent="afterSent" />
  </div>
</template>

<style scoped>
.notification-page { gap: 17px; }
.notification-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid var(--sakura-500); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { max-width: 760px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.channel-state { min-width: 265px; display: flex; align-items: center; gap: 10px; padding: 12px 14px; border: 1px solid #cfe5db; border-radius: 8px; background: #f3faf6; }
.channel-icon { width: 35px; height: 35px; flex: 0 0 35px; display: grid; place-items: center; border-radius: 7px; color: #287258; background: #e1f3e9; font-size: 17px; }
.channel-state > div { min-width: 0; flex: 1; display: grid; gap: 3px; }
.channel-state strong { color: #255f4c; font-size: 12px; }
.channel-state small { color: #5d7d70; font-size: 9px; line-height: 1.4; }
.notification-metrics { grid-template-columns: repeat(4, minmax(150px, 1fr)); gap: 10px; }
.notification-metrics :deep(.metric-card) { min-height: 117px; padding: 15px; }
.status-strip { display: grid; grid-template-columns: repeat(5, minmax(100px, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.status-strip button { min-height: 54px; display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 0 15px; border: 0; border-right: 1px solid var(--line); color: var(--ink-500); background: white; cursor: pointer; }
.status-strip button:last-child { border-right: 0; }
.status-strip button.active { color: var(--sakura-700); background: var(--sakura-50); }
.status-strip span { font-size: 10px; }.status-strip strong { color: inherit; font-size: 17px; letter-spacing: 0; }
.notification-list-section { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.section-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 17px 18px; border-bottom: 1px solid var(--line); }
.section-heading > div:first-child { min-width: 0; display: grid; gap: 3px; }
.section-heading > div:first-child > span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.section-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; }
.section-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.section-actions { display: flex; align-items: center; gap: 7px; }
.notification-filter-bar { margin: 14px 16px; border: 0; background: var(--surface-muted); }
.notification-filter-bar :deep(.el-input) { min-width: 220px; flex: 1; }
.notification-filter-bar :deep(.el-select) { width: 145px; }
.notification-table-wrap { min-width: 0; overflow-x: auto; }
.notification-table-wrap :deep(.el-table) { min-width: 1050px; }
.notification-cell, .audience-cell, .delivery-cell { min-width: 0; display: flex; }
.notification-cell { align-items: flex-start; gap: 9px; }
.notification-cell-icon { width: 32px; height: 32px; flex: 0 0 32px; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-50); }
.notification-cell > div, .audience-cell, .delivery-cell { display: grid; gap: 3px; }
.notification-cell strong { overflow: hidden; color: var(--ink-900); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.notification-cell small, .audience-cell small, .delivery-cell small, .table-subline { color: var(--ink-500); font-size: 9px; }
.notification-cell p { max-width: 380px; margin: 2px 0 0; overflow: hidden; color: var(--ink-600); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.audience-cell strong, .delivery-cell strong { color: var(--ink-800); font-size: 11px; }
.row-actions { display: flex; gap: 5px; }
.table-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 16px; border-top: 1px solid var(--line); }
.table-footer > span { color: var(--ink-500); font-size: 10px; }
.notification-boundary { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 15px; border: 1px solid #d9e2e9; border-radius: 8px; background: #f7fafc; }
.notification-boundary > div { display: flex; align-items: flex-start; gap: 9px; min-width: 0; }
.notification-boundary .el-icon { margin-top: 2px; color: #39769b; }
.notification-boundary > div > div { display: grid; gap: 3px; }
.notification-boundary strong { color: var(--ink-800); font-size: 11px; }
.notification-boundary span { color: var(--ink-500); font-size: 10px; line-height: 1.5; }
@media (max-width: 900px) {
  .notification-hero { align-items: flex-start; flex-direction: column; }
  .channel-state { width: 100%; min-width: 0; }
  .notification-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .notification-filter-bar { align-items: stretch; flex-wrap: wrap; }
  .notification-filter-bar :deep(.el-input) { flex: 1 1 100%; }
}
@media (max-width: 620px) {
  .notification-metrics { grid-template-columns: 1fr 1fr; }
  .status-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .status-strip button:nth-child(2n) { border-right: 0; }
  .status-strip button:nth-child(-n + 3) { border-bottom: 1px solid var(--line); }
  .section-heading { align-items: flex-start; flex-direction: column; }
  .notification-boundary { align-items: flex-start; flex-direction: column; }
  .table-footer { align-items: flex-start; flex-direction: column; }
}
</style>
