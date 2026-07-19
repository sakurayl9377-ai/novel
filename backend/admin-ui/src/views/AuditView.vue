<script setup lang="ts">
import {
  DocumentChecked,
  Filter,
  Refresh,
  Search,
  TrendCharts,
  User,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import AuditDetailDrawer from '@/components/audit/AuditDetailDrawer.vue';
import MetricCard from '@/components/MetricCard.vue';
import { getAuditWorkbench } from '@/services/audit';
import type {
  AuditItem,
  AuditMethod,
  AuditPeriod,
  AuditStatus,
  AuditWorkbenchResponse,
} from '@/types/audit';
import { formatCompactNumber, formatDateTime } from '@/utils/format';
import {
  auditActorLabel,
  auditMethodLabel,
  auditMethodTone,
  auditStatusLabel,
  auditStatusTone,
} from '@/utils/system-operations';

const periodOptions: Array<{ value: AuditPeriod; label: string }> = [
  { value: '24h', label: '最近 24 小时' },
  { value: '7d', label: '最近 7 天' },
  { value: '30d', label: '最近 30 天' },
  { value: 'all', label: '全部历史' },
];

const methodOptions: Array<{ value: AuditMethod; label: string }> = [
  { value: '', label: '全部方法' },
  { value: 'GET', label: 'GET 读取' },
  { value: 'POST', label: 'POST 创建/执行' },
  { value: 'PUT', label: 'PUT 更新' },
  { value: 'PATCH', label: 'PATCH 局部更新' },
  { value: 'DELETE', label: 'DELETE 删除' },
];

const statusOptions: Array<{ value: AuditStatus; label: string }> = [
  { value: '', label: '全部结果' },
  { value: 'success', label: '成功请求' },
  { value: 'error', label: '失败请求' },
];

const methodMix: AuditMethod[] = ['GET', 'POST', 'PATCH', 'PUT', 'DELETE'];

const loading = ref(false);
const initialized = ref(false);
const workbench = ref<AuditWorkbenchResponse>(emptyWorkbench());
const selectedItem = ref<AuditItem | null>(null);
const detailOpen = ref(false);
const query = reactive({
  q: '',
  period: '7d' as AuditPeriod,
  method: '' as AuditMethod,
  status: '' as AuditStatus,
  page: 1,
  pageSize: 20,
});

const filterCount = computed(() => [
  query.q,
  query.period !== '7d' ? query.period : '',
  query.method,
  query.status,
].filter(Boolean).length);

const successRate = computed(() => Math.max(0, 1 - Number(workbench.value.summary.errorRate || 0)));

onMounted(() => void loadAudit());

async function loadAudit(): Promise<void> {
  loading.value = true;
  try {
    workbench.value = await getAuditWorkbench({
      q: query.q.trim(),
      period: query.period,
      method: query.method,
      status: query.status,
      page: query.page,
      pageSize: query.pageSize,
    });
  } catch (error) {
    ElMessage.error(errorMessage(error, '审计日志加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function applyFilters(): void {
  query.page = 1;
  void loadAudit();
}

function resetFilters(): void {
  Object.assign(query, { q: '', period: '7d', method: '', status: '', page: 1 });
  void loadAudit();
}

function changePage(page: number): void {
  query.page = page;
  void loadAudit();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadAudit();
}

function openDetail(item: AuditItem): void {
  selectedItem.value = item;
  detailOpen.value = true;
}

function toggleMethod(method: AuditMethod): void {
  query.method = query.method === method ? '' : method;
  applyFilters();
}

function asAuditItem(row: unknown): AuditItem {
  return row as AuditItem;
}

function methodCount(method: string): number {
  return workbench.value.methodCounts.find((item) => item.key === method)?.count || 0;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): AuditWorkbenchResponse {
  return {
    generatedAt: '',
    page: 1,
    pageSize: 20,
    total: 0,
    filters: { period: '7d', q: '', method: '', status: '' },
    summary: {
      total: 0,
      errors: 0,
      sensitiveActions: 0,
      uniqueAdmins: 0,
      lastAt: '',
      errorRate: 0,
    },
    statusCounts: { success: 0, error: 0 },
    methodCounts: [],
    items: [],
  };
}
</script>

<template>
  <div class="page-stack system-page audit-page">
    <section class="workbench-hero">
      <div class="hero-copy">
        <span class="eyebrow">SYSTEM GOVERNANCE</span>
        <h2>审计日志</h2>
        <p>按管理员、请求路径和结果快速定位后台操作。日志只展示请求元数据，不暴露请求体或敏感配置。</p>
      </div>
      <div class="hero-controls">
        <ElSelect v-model="query.period" aria-label="审计时间范围" @change="applyFilters">
          <ElOption v-for="item in periodOptions" :key="item.value" :label="item.label" :value="item.value" />
        </ElSelect>
        <ElButton :icon="Refresh" :loading="loading" @click="loadAudit">刷新</ElButton>
      </div>
    </section>

    <ElAlert
      title="审计口径"
      type="info"
      :closable="false"
      show-icon
    >
      <template #default>成功与失败按 HTTP 状态码区分；非 GET 请求计入敏感操作，用于检查后台变更是否有可追溯记录。</template>
    </ElAlert>

    <ElSkeleton v-if="!initialized && loading" :rows="8" animated />
    <template v-else>
      <section class="metric-grid audit-metrics">
        <MetricCard label="请求总量" :value="formatCompactNumber(workbench.summary.total)" hint="当前时间范围" :icon="DocumentChecked" />
        <MetricCard label="成功率" :value="`${(successRate * 100).toFixed(1)}%`" hint="按 HTTP 状态码" :icon="TrendCharts" :tone="successRate < 0.98 ? 'warning' : 'success'" />
        <MetricCard label="失败请求" :value="formatCompactNumber(workbench.summary.errors)" hint="状态码 ≥ 400" :icon="WarningFilled" :tone="workbench.summary.errors ? 'danger' : 'success'" />
        <MetricCard label="敏感操作" :value="formatCompactNumber(workbench.summary.sensitiveActions)" hint="POST / PATCH / DELETE 等" :icon="Filter" />
        <MetricCard label="涉及管理员" :value="formatCompactNumber(workbench.summary.uniqueAdmins)" hint="去重后的操作人" :icon="User" />
        <MetricCard label="最近记录" :value="formatDateTime(workbench.summary.lastAt)" hint="服务器记录时间" :icon="Refresh" />
      </section>

      <section class="system-grid">
        <article class="system-panel signal-panel">
          <header class="panel-heading">
            <div><span>REQUEST OUTCOME</span><h3>请求结果</h3><p>点击筛选条可快速切换结果</p></div>
            <ElIcon><TrendCharts /></ElIcon>
          </header>
          <div class="outcome-grid">
            <button type="button" :class="['outcome-card', { active: query.status === 'success' }]" @click="query.status = query.status === 'success' ? '' : 'success'; applyFilters()">
              <span>成功请求</span><strong>{{ workbench.statusCounts.success.toLocaleString() }}</strong><small>可正常完成</small>
            </button>
            <button type="button" :class="['outcome-card danger', { active: query.status === 'error' }]" @click="query.status = query.status === 'error' ? '' : 'error'; applyFilters()">
              <span>失败请求</span><strong>{{ workbench.statusCounts.error.toLocaleString() }}</strong><small>需要关注</small>
            </button>
          </div>
        </article>

        <article class="system-panel signal-panel">
          <header class="panel-heading">
            <div><span>METHOD MIX</span><h3>操作类型</h3><p>用请求方法判断变更量级</p></div>
            <ElIcon><Filter /></ElIcon>
          </header>
          <div class="method-list">
            <button v-for="method in methodMix" :key="method" type="button" :class="{ active: query.method === method }" @click="toggleMethod(method)">
              <ElTag :type="auditMethodTone(method)" effect="plain">{{ auditMethodLabel(method) }}</ElTag>
              <strong>{{ methodCount(method).toLocaleString() }}</strong>
            </button>
            <ElEmpty v-if="!workbench.methodCounts.length" :image-size="42" description="暂无请求记录" />
          </div>
        </article>
      </section>

      <section class="system-panel table-panel">
        <header class="section-heading">
          <div><span>AUDIT TRAIL</span><h3>操作记录</h3><p>{{ workbench.total.toLocaleString() }} 条记录 · 点击行查看上下文</p></div>
          <ElTag type="info" effect="plain">{{ periodOptions.find((item) => item.value === query.period)?.label }}</ElTag>
        </header>
        <div class="filter-bar system-filter-bar">
          <ElInput v-model="query.q" clearable :prefix-icon="Search" placeholder="路径、管理员、IP 或请求编号" @keyup.enter="applyFilters" @clear="applyFilters" />
          <ElSelect v-model="query.method" placeholder="全部方法" @change="applyFilters">
            <ElOption v-for="item in methodOptions" :key="item.value || 'all'" :label="item.label" :value="item.value" />
          </ElSelect>
          <ElSelect v-model="query.status" placeholder="全部结果" @change="applyFilters">
            <ElOption v-for="item in statusOptions" :key="item.value || 'all'" :label="item.label" :value="item.value" />
          </ElSelect>
          <ElButton type="primary" :icon="Search" @click="applyFilters">查询</ElButton>
          <ElButton v-if="filterCount" :icon="Filter" @click="resetFilters">清除 {{ filterCount }}</ElButton>
        </div>
        <div v-loading="loading" class="table-wrap audit-table-wrap">
          <ElTable
            :data="workbench.items"
            row-key="id"
            empty-text="当前筛选下没有审计记录"
            @row-click="(row) => openDetail(asAuditItem(row))"
          >
            <ElTableColumn label="操作" min-width="360">
              <template #default="{ row }">
                <div class="operation-cell">
                  <span class="operation-icon"><ElIcon><DocumentChecked /></ElIcon></span>
                  <div><strong>{{ asAuditItem(row).path || '未记录路径' }}</strong><small>{{ asAuditItem(row).requestId || '没有请求编号' }}</small></div>
                </div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="方法" width="118">
              <template #default="{ row }"><ElTag :type="auditMethodTone(asAuditItem(row).method)" effect="plain">{{ auditMethodLabel(asAuditItem(row).method) }}</ElTag></template>
            </ElTableColumn>
            <ElTableColumn label="管理员" min-width="150">
              <template #default="{ row }"><div class="compact-cell"><strong>{{ auditActorLabel(asAuditItem(row)) }}</strong><small>{{ asAuditItem(row).admin?.email || '系统记录' }}</small></div></template>
            </ElTableColumn>
            <ElTableColumn label="结果" width="105">
              <template #default="{ row }"><ElTag :type="auditStatusTone(asAuditItem(row).statusCode)" effect="plain">{{ asAuditItem(row).statusCode }} {{ auditStatusLabel(asAuditItem(row).statusCode) }}</ElTag></template>
            </ElTableColumn>
            <ElTableColumn label="来源 IP" width="145"><template #default="{ row }">{{ asAuditItem(row).ip || '—' }}</template></ElTableColumn>
            <ElTableColumn label="发生时间" width="145"><template #default="{ row }">{{ formatDateTime(asAuditItem(row).createdAt) }}</template></ElTableColumn>
            <ElTableColumn label="查看" width="78" fixed="right"><template #default="{ row }"><ElButton circle :icon="DocumentChecked" aria-label="查看审计详情" @click.stop="openDetail(asAuditItem(row))" /></template></ElTableColumn>
          </ElTable>
          <ElEmpty v-if="initialized && !loading && !workbench.items.length" :image-size="60" description="当前筛选下没有审计记录" />
        </div>
        <footer v-if="workbench.total" class="table-footer">
          <span>第 {{ workbench.page }} 页 · 共 {{ workbench.total.toLocaleString() }} 条</span>
          <ElPagination background layout="sizes, prev, pager, next" :current-page="query.page" :page-size="query.pageSize" :page-sizes="[10, 20, 50]" :total="workbench.total" @current-change="changePage" @size-change="changePageSize" />
        </footer>
      </section>
    </template>

    <AuditDetailDrawer v-model="detailOpen" :item="selectedItem" />
  </div>
</template>

<style scoped>
.system-page { gap: 17px; }
.workbench-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid var(--sakura-500); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { max-width: 780px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.hero-controls { display: flex; flex: 0 0 auto; align-items: center; gap: 8px; }
.hero-controls :deep(.el-select) { width: 160px; }
.audit-metrics { grid-template-columns: repeat(6, minmax(140px, 1fr)); gap: 10px; }
.audit-metrics :deep(.metric-card) { min-height: 115px; padding: 14px; }
.system-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.system-panel { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }
.panel-heading, .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 16px 17px; border-bottom: 1px solid var(--line); }
.panel-heading > div, .section-heading > div:first-child { min-width: 0; display: grid; gap: 3px; }
.panel-heading span, .section-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.panel-heading h3, .section-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; }
.panel-heading p, .section-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.panel-heading > .el-icon { color: var(--sakura-500); font-size: 18px; }
.outcome-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; padding: 16px; }
.outcome-card { min-height: 100px; display: grid; gap: 6px; padding: 14px; border: 1px solid var(--line); border-radius: 7px; text-align: left; color: var(--ink-500); background: var(--surface-muted); }
.outcome-card:hover, .outcome-card.active { border-color: #bfe1ce; color: #237355; background: #f2faf5; }
.outcome-card.danger:hover, .outcome-card.danger.active { border-color: #f0c0ca; color: #b33d55; background: #fff5f6; }
.outcome-card strong { color: var(--ink-900); font-size: 25px; }
.outcome-card small { font-size: 10px; }
.method-list { display: grid; gap: 0; padding: 5px 17px 8px; }
.method-list button { display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 43px; padding: 0; border: 0; border-bottom: 1px solid var(--line); background: transparent; }
.method-list button:last-of-type { border-bottom: 0; }
.method-list button:hover strong, .method-list button.active strong { color: var(--sakura-600); }
.method-list strong { color: var(--ink-800); font-size: 14px; }
.table-panel { overflow: hidden; }
.section-heading { border-bottom: 0; }
.filter-bar { display: flex; align-items: center; gap: 8px; padding: 13px 16px; }
.system-filter-bar { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.system-filter-bar :deep(.el-input) { min-width: 230px; flex: 1; }
.system-filter-bar :deep(.el-select) { width: 150px; }
.table-wrap { min-width: 0; overflow-x: auto; }
.audit-table-wrap :deep(.el-table) { min-width: 1050px; }
.operation-cell, .compact-cell { min-width: 0; display: flex; align-items: flex-start; gap: 9px; }
.operation-cell > div, .compact-cell { display: grid; gap: 3px; }
.operation-icon { width: 30px; height: 30px; flex: 0 0 30px; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-50); }
.operation-cell strong, .compact-cell strong { overflow: hidden; color: var(--ink-900); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.operation-cell small, .compact-cell small { overflow: hidden; color: var(--ink-500); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.table-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 16px; border-top: 1px solid var(--line); }
.table-footer > span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 1320px) { .audit-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); } }
@media (max-width: 900px) {
  .workbench-hero { align-items: flex-start; flex-direction: column; }
  .hero-controls { width: 100%; }
  .hero-controls :deep(.el-select) { flex: 1; }
  .system-grid { grid-template-columns: 1fr; }
  .system-filter-bar { align-items: stretch; flex-wrap: wrap; }
  .system-filter-bar :deep(.el-input) { flex: 1 1 100%; }
}
@media (max-width: 620px) {
  .audit-metrics { grid-template-columns: 1fr 1fr; }
  .outcome-grid { grid-template-columns: 1fr 1fr; }
  .table-footer { align-items: flex-start; flex-direction: column; }
}
</style>
