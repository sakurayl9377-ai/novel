<script setup lang="ts">
import {
  CircleCheck,
  DataAnalysis,
  Document,
  Filter,
  Monitor,
  Refresh,
  Search,
  Timer,
  TrendCharts,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import AnalyticsErrorDrawer from '@/components/analytics/AnalyticsErrorDrawer.vue';
import MetricCard from '@/components/MetricCard.vue';
import { getAnalyticsErrors, getAnalyticsOverview } from '@/services/analytics';
import type {
  AnalyticsDays,
  AnalyticsErrorGroup,
  AnalyticsErrorsResponse,
  AnalyticsOverviewResponse,
} from '@/types/analytics';
import { formatCompactNumber, formatDateTime, parseServerTime } from '@/utils/format';
import {
  analyticsErrorSeverity,
  analyticsEventLabel,
  analyticsPercent,
  analyticsTrendMaximum,
} from '@/utils/analytics';

const dayOptions: Array<{ value: AnalyticsDays; label: string }> = [
  { value: 1, label: '最近 24 小时' },
  { value: 7, label: '最近 7 天' },
  { value: 14, label: '最近 14 天' },
  { value: 30, label: '最近 30 天' },
  { value: 90, label: '最近 90 天' },
];

const loading = ref(false);
const initialized = ref(false);
const overview = ref<AnalyticsOverviewResponse>(emptyOverview());
const errors = ref<AnalyticsErrorsResponse>(emptyErrors());
const selectedError = ref<AnalyticsErrorGroup | null>(null);
const errorDrawerOpen = ref(false);
const query = reactive({
  days: 7 as AnalyticsDays,
  q: '',
  versionCode: 0,
  fatal: false,
  page: 1,
  pageSize: 20,
});

const filterCount = computed(() => [
  query.q,
  query.versionCode,
  query.fatal,
].filter(Boolean).length);
const trendPoints = computed(() => overview.value.daily.slice(-14));
const trendMaximum = computed(() => analyticsTrendMaximum(trendPoints.value));
const slowFrameRate = computed(() => overview.value.frameMetrics.slow16Rate + overview.value.frameMetrics.slow32Rate);
const qualityState = computed(() => {
  const quality = overview.value.dataQuality;
  if (!quality.eventCount) {
    return {
      type: 'warning' as const,
      title: '当前时间范围没有收到埋点数据',
      detail: '指标显示为 0 只代表没有样本，不代表客户端运行正常。',
    };
  }
  const lastEvent = parseServerTime(quality.lastEventAt);
  const ageHours = lastEvent ? Math.max(0, (Date.now() - lastEvent.getTime()) / 3600000) : Number.POSITIVE_INFINITY;
  if (ageHours > 24) {
    return {
      type: 'warning' as const,
      title: '埋点数据可能已经滞后',
      detail: `最近一次事件：${formatDateTime(quality.lastEventAt)}，请先确认客户端上报链路。`,
    };
  }
  return {
    type: 'success' as const,
    title: '埋点数据正在流入',
    detail: `最近一次事件：${formatDateTime(quality.lastEventAt)}，覆盖 ${formatCompactNumber(quality.reportingInstalls)} 个安装。`,
  };
});

onMounted(() => void loadAnalytics());

async function loadAnalytics(): Promise<void> {
  loading.value = true;
  try {
    const [overviewData, errorData] = await Promise.all([
      getAnalyticsOverview(query.days),
      getAnalyticsErrors({
        days: query.days,
        q: query.q.trim(),
        versionCode: query.versionCode,
        fatal: query.fatal,
        page: query.page,
        pageSize: query.pageSize,
      }),
    ]);
    overview.value = overviewData;
    errors.value = errorData;
  } catch (error) {
    ElMessage.error(errorMessage(error, '质量数据加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function changeDays(value: AnalyticsDays): void {
  query.days = value;
  query.page = 1;
  void loadAnalytics();
}

function searchErrors(): void {
  query.page = 1;
  void loadAnalytics();
}

function resetFilters(): void {
  Object.assign(query, { q: '', versionCode: 0, fatal: false, page: 1 });
  void loadAnalytics();
}

function changePage(page: number): void {
  query.page = page;
  void loadAnalytics();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadAnalytics();
}

function openError(item: AnalyticsErrorGroup): void {
  selectedError.value = item;
  errorDrawerOpen.value = true;
}

function asErrorGroup(row: unknown): AnalyticsErrorGroup {
  return row as AnalyticsErrorGroup;
}

function trendBarWidth(value: number): string {
  if (!value) return '0%';
  return `${Math.max(4, Math.round((value / trendMaximum.value) * 100))}%`;
}

function formatMilliseconds(value: number): string {
  const number = Number(value || 0);
  return number > 0 ? `${number.toFixed(number >= 100 ? 0 : 1)} ms` : '—';
}

function errorTone(item: AnalyticsErrorGroup): 'danger' | 'warning' {
  return analyticsErrorSeverity(item) === 'fatal' ? 'danger' : 'warning';
}

function errorLabel(item: AnalyticsErrorGroup): string {
  return analyticsErrorSeverity(item) === 'fatal' ? '致命' : '普通';
}

function versionLabel(versionCode: number): string {
  if (!versionCode) return '全部版本';
  const item = overview.value.versions.find((version) => version.versionCode === versionCode);
  return item ? `${item.versionName || '未命名'} (#${item.versionCode})` : `版本 #${versionCode}`;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyOverview(): AnalyticsOverviewResponse {
  return {
    days: 7,
    generatedAt: '',
    dataQuality: { eventCount: 0, errorCount: 0, reportingInstalls: 0, lastEventAt: '', lastErrorAt: '' },
    summary: { events: 0, activeInstalls: 0, sessions: 0, errors: 0, fatalErrors: 0, errorGroups: 0, crashFreeRate: 1 },
    frameMetrics: { samples: 0, frames: 0, slow16: 0, slow32: 0, frozen700: 0, maxBuildMs: 0, maxRasterMs: 0, slow16Rate: 0, slow32Rate: 0 },
    daily: [],
    topScreens: [],
    topEvents: [],
    versions: [],
  };
}

function emptyErrors(): AnalyticsErrorsResponse {
  return { page: 1, pageSize: 20, total: 0, days: 7, items: [] };
}
</script>

<template>
  <div class="page-stack analytics-page">
    <section class="analytics-hero">
      <div class="hero-copy">
        <span class="eyebrow">APP QUALITY OBSERVABILITY</span>
        <h2>质量分析工作台</h2>
        <p>先确认数据是否新鲜，再判断崩溃、错误、卡顿和版本分布；每个错误分组都能展开查看原始上下文。</p>
      </div>
      <div class="hero-controls">
        <ElSelect :model-value="query.days" aria-label="统计范围" @update:model-value="changeDays">
          <ElOption v-for="item in dayOptions" :key="item.value" :label="item.label" :value="item.value" />
        </ElSelect>
        <ElButton :icon="Refresh" :loading="loading" @click="loadAnalytics">刷新数据</ElButton>
      </div>
    </section>

    <ElAlert :title="qualityState.title" :type="qualityState.type" :closable="false" show-icon>
      <template #default><span>{{ qualityState.detail }}</span></template>
    </ElAlert>

    <ElSkeleton v-if="!initialized && loading" :rows="10" animated />
    <template v-else>
      <section class="metric-grid analytics-metrics">
        <MetricCard label="活跃安装" :value="formatCompactNumber(overview.summary.activeInstalls)" :hint="`${formatCompactNumber(overview.summary.sessions)} 个会话`" :icon="Monitor" />
        <MetricCard label="事件量" :value="formatCompactNumber(overview.summary.events)" :hint="`最近 ${overview.days} 天`" :icon="DataAnalysis" />
        <MetricCard label="无崩溃会话" :value="analyticsPercent(overview.summary.crashFreeRate, 2)" hint="按会话计算" :icon="CircleCheck" :tone="overview.summary.crashFreeRate < 0.99 ? 'warning' : 'success'" />
        <MetricCard label="错误分组" :value="formatCompactNumber(overview.summary.errorGroups)" :hint="`${formatCompactNumber(overview.summary.errors)} 次上报`" :icon="WarningFilled" :tone="overview.summary.errorGroups ? 'warning' : 'success'" />
        <MetricCard label="致命错误" :value="formatCompactNumber(overview.summary.fatalErrors)" hint="未捕获异常会话" :icon="WarningFilled" :tone="overview.summary.fatalErrors ? 'danger' : 'success'" />
        <MetricCard label="慢帧样本" :value="analyticsPercent(slowFrameRate, 2)" :hint="`>16.7ms ${analyticsPercent(overview.frameMetrics.slow16Rate, 1)}`" :icon="Timer" :tone="slowFrameRate > 0.08 ? 'warning' : 'default'" />
      </section>

      <section class="analytics-grid">
        <article class="analytics-panel">
          <header class="panel-heading">
            <div><span>RENDER HEALTH</span><h3>渲染性能</h3><p>帧率采样只在有数据时参与判断</p></div>
            <ElIcon><Timer /></ElIcon>
          </header>
          <div class="performance-summary">
            <strong>{{ overview.frameMetrics.frames.toLocaleString() }}</strong><span>帧采样总数</span>
          </div>
          <div class="performance-list">
            <div><span>&gt;16.7ms</span><b>{{ overview.frameMetrics.slow16.toLocaleString() }}</b><em>{{ analyticsPercent(overview.frameMetrics.slow16Rate, 2) }}</em></div>
            <div><span>&gt;32ms</span><b>{{ overview.frameMetrics.slow32.toLocaleString() }}</b><em>{{ analyticsPercent(overview.frameMetrics.slow32Rate, 2) }}</em></div>
            <div><span>&gt;700ms</span><b>{{ overview.frameMetrics.frozen700.toLocaleString() }}</b><em>冻结帧</em></div>
          </div>
          <div class="performance-foot"><span>最大构建 {{ formatMilliseconds(overview.frameMetrics.maxBuildMs) }}</span><span>最大栅格 {{ formatMilliseconds(overview.frameMetrics.maxRasterMs) }}</span></div>
        </article>

        <article class="analytics-panel">
          <header class="panel-heading">
            <div><span>VERSION COVERAGE</span><h3>版本活跃分布</h3><p>用于定位版本覆盖和升级风险</p></div>
            <ElIcon><TrendCharts /></ElIcon>
          </header>
          <div v-if="overview.versions.length" class="version-list">
            <div v-for="item in overview.versions.slice(0, 6)" :key="`${item.versionCode}-${item.versionName}`">
              <div><strong>{{ item.versionName || '未命名版本' }}</strong><small>#{{ item.versionCode }} · {{ item.events.toLocaleString() }} 事件</small></div>
              <b>{{ item.activeInstalls.toLocaleString() }}</b>
            </div>
          </div>
          <ElEmpty v-else :image-size="48" description="暂无版本上报" />
        </article>
      </section>

      <section class="analytics-panel trend-panel">
        <header class="panel-heading">
          <div><span>DAILY SIGNAL</span><h3>每日趋势</h3><p>按北京时间自然日聚合，错误单独显示致命数量</p></div>
          <ElIcon><TrendCharts /></ElIcon>
        </header>
        <div v-if="trendPoints.length" class="trend-table-wrap">
          <div class="trend-row trend-head"><span>日期</span><span>事件</span><span>活跃安装</span><span>会话</span><span>错误 / 致命</span></div>
          <div v-for="point in trendPoints" :key="point.day" class="trend-row">
            <strong>{{ point.day }}</strong>
            <span><i class="trend-bar event" :style="{ width: trendBarWidth(point.events) }" />{{ point.events.toLocaleString() }}</span>
            <span><i class="trend-bar install" :style="{ width: trendBarWidth(point.activeInstalls) }" />{{ point.activeInstalls.toLocaleString() }}</span>
            <span>{{ point.sessions.toLocaleString() }}</span>
            <span :class="{ danger: point.fatalErrors > 0 }">{{ point.errors.toLocaleString() }} / {{ point.fatalErrors.toLocaleString() }}</span>
          </div>
        </div>
        <ElEmpty v-else :image-size="54" description="当前时间范围没有每日样本" />
      </section>

      <section class="analytics-grid">
        <article class="analytics-panel list-panel">
          <header class="panel-heading"><div><span>SCREEN RETENTION</span><h3>页面停留</h3><p>按页面浏览事件统计</p></div><ElIcon><Document /></ElIcon></header>
          <div v-if="overview.topScreens.length" class="rank-list">
            <div v-for="(item, index) in overview.topScreens.slice(0, 8)" :key="item.screen">
              <span class="rank-number">{{ index + 1 }}</span>
              <div><strong>{{ item.screen || '未命名页面' }}</strong><small>{{ item.views.toLocaleString() }} 次 · {{ item.uniqueInstalls.toLocaleString() }} 个安装</small></div>
              <em>{{ formatMilliseconds(item.avgDurationMs) }}</em>
            </div>
          </div>
          <ElEmpty v-else :image-size="48" description="暂无页面数据" />
        </article>
        <article class="analytics-panel list-panel">
          <header class="panel-heading"><div><span>EVENT MIX</span><h3>关键事件</h3><p>失败次数用于定位功能链路</p></div><ElIcon><DataAnalysis /></ElIcon></header>
          <div v-if="overview.topEvents.length" class="rank-list">
            <div v-for="(item, index) in overview.topEvents.slice(0, 8)" :key="item.name">
              <span class="rank-number">{{ index + 1 }}</span>
              <div><strong>{{ analyticsEventLabel(item.name) }}</strong><small>{{ item.count.toLocaleString() }} 次 · {{ item.uniqueInstalls.toLocaleString() }} 个安装</small></div>
              <em :class="{ danger: item.failures > 0 }">失败 {{ item.failures.toLocaleString() }}</em>
            </div>
          </div>
          <ElEmpty v-else :image-size="48" description="暂无事件数据" />
        </article>
      </section>

      <section class="analytics-panel error-section">
        <header class="panel-heading section-heading">
          <div><span>ERROR GROUPS</span><h3>错误分组</h3><p>{{ errors.total.toLocaleString() }} 个指纹 · 点击记录查看堆栈和原始元数据</p></div>
          <ElTag type="info" effect="plain">{{ versionLabel(query.versionCode) }}</ElTag>
        </header>
        <div class="filter-bar analytics-filter-bar">
          <ElInput v-model="query.q" clearable :prefix-icon="Search" placeholder="错误类型、消息、页面或堆栈" @keyup.enter="searchErrors" @clear="searchErrors" />
          <ElSelect v-model="query.versionCode" clearable placeholder="全部版本" @change="searchErrors">
            <ElOption label="全部版本" :value="0" />
            <ElOption v-for="item in overview.versions" :key="item.versionCode" :label="`${item.versionName || '未命名'} (#${item.versionCode})`" :value="item.versionCode" />
          </ElSelect>
          <ElCheckbox v-model="query.fatal" label="只看致命" @change="searchErrors" />
          <ElButton type="primary" :icon="Search" @click="searchErrors">查询</ElButton>
          <ElButton v-if="filterCount" :icon="Filter" @click="resetFilters">清除 {{ filterCount }}</ElButton>
        </div>
        <div v-loading="loading" class="error-table-wrap">
          <ElTable
            :data="errors.items"
            row-key="fingerprint"
            empty-text="当前筛选下没有错误分组"
            @row-click="(row) => openError(row as AnalyticsErrorGroup)"
          >
            <ElTableColumn label="错误" min-width="310">
              <template #default="{ row }">
                <div class="error-cell"><span class="severity-icon" :class="`tone-${errorTone(asErrorGroup(row))}`"><ElIcon><WarningFilled /></ElIcon></span><div><strong>{{ asErrorGroup(row).type || '未命名错误' }}</strong><small>{{ asErrorGroup(row).message || '没有错误消息' }}</small></div></div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="级别" width="90"><template #default="{ row }"><ElTag :type="errorTone(asErrorGroup(row))" effect="plain">{{ errorLabel(asErrorGroup(row)) }}</ElTag></template></ElTableColumn>
            <ElTableColumn label="发生次数" width="110" align="right"><template #default="{ row }"><strong>{{ asErrorGroup(row).occurrences.toLocaleString() }}</strong></template></ElTableColumn>
            <ElTableColumn label="受影响安装" width="125" align="right"><template #default="{ row }">{{ asErrorGroup(row).affectedInstalls.toLocaleString() }}</template></ElTableColumn>
            <ElTableColumn label="最近出现" width="145"><template #default="{ row }">{{ formatDateTime(asErrorGroup(row).lastSeenAt) }}</template></ElTableColumn>
            <ElTableColumn label="操作" width="95"><template #default="{ row }"><ElButton circle :icon="Document" :aria-label="`查看${asErrorGroup(row).type || '错误'}详情`" @click.stop="openError(asErrorGroup(row))" /></template></ElTableColumn>
          </ElTable>
          <ElEmpty v-if="initialized && !loading && !errors.items.length" :image-size="60" description="当前筛选下没有错误分组" />
        </div>
        <footer v-if="errors.total" class="table-footer"><span>第 {{ errors.page }} 页 · 共 {{ errors.total.toLocaleString() }} 个错误分组</span><ElPagination background layout="sizes, prev, pager, next" :current-page="query.page" :page-size="query.pageSize" :page-sizes="[10, 20, 50]" :total="errors.total" @current-change="changePage" @size-change="changePageSize" /></footer>
      </section>
    </template>

    <AnalyticsErrorDrawer v-model="errorDrawerOpen" :error="selectedError" />
  </div>
</template>

<style scoped>
.analytics-page { gap: 17px; }
.analytics-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid var(--sakura-500); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { max-width: 780px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.hero-controls { display: flex; flex: 0 0 auto; align-items: center; gap: 8px; }
.hero-controls :deep(.el-select) { width: 160px; }
.analytics-metrics { grid-template-columns: repeat(6, minmax(140px, 1fr)); gap: 10px; }
.analytics-metrics :deep(.metric-card) { min-height: 115px; padding: 14px; }
.analytics-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }
.analytics-panel { min-width: 0; border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.panel-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 16px 17px; border-bottom: 1px solid var(--line); }
.panel-heading > div { min-width: 0; display: grid; gap: 3px; }
.panel-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.panel-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; }
.panel-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.panel-heading > .el-icon { color: var(--sakura-500); font-size: 18px; }
.performance-summary { display: flex; align-items: baseline; gap: 8px; padding: 18px 17px 8px; }
.performance-summary strong { color: var(--ink-900); font-size: 26px; }
.performance-summary span { color: var(--ink-500); font-size: 11px; }
.performance-list { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; padding: 8px 17px 14px; }
.performance-list div { display: grid; gap: 4px; padding: 10px; background: var(--surface-muted); }
.performance-list span, .performance-list em { color: var(--ink-500); font-size: 10px; font-style: normal; }
.performance-list b { color: var(--ink-900); font-size: 15px; }
.performance-foot { display: flex; flex-wrap: wrap; gap: 12px; padding: 11px 17px; border-top: 1px solid var(--line); color: var(--ink-500); font-size: 10px; }
.version-list { display: grid; gap: 0; padding: 4px 17px 8px; }
.version-list > div { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 11px 0; border-bottom: 1px solid var(--line); }
.version-list > div:last-child { border-bottom: 0; }
.version-list > div > div { min-width: 0; display: grid; gap: 3px; }
.version-list strong { overflow: hidden; color: var(--ink-800); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.version-list small { color: var(--ink-500); font-size: 10px; }
.version-list b { color: var(--ink-900); font-size: 15px; }
.trend-panel { overflow: hidden; }
.trend-table-wrap { min-width: 0; overflow-x: auto; padding: 6px 17px 16px; }
.trend-row { min-width: 680px; display: grid; grid-template-columns: 120px 1.4fr 1.1fr 110px 130px; align-items: center; gap: 12px; min-height: 42px; border-bottom: 1px solid var(--line); color: var(--ink-600); font-size: 11px; }
.trend-row:last-child { border-bottom: 0; }
.trend-head { min-height: 32px; color: var(--ink-500); font-size: 10px; }
.trend-row > span:not(:last-child) { display: flex; align-items: center; gap: 7px; }
.trend-row strong { color: var(--ink-800); font-size: 11px; }
.trend-row .danger { color: #c64d61; }
.trend-bar { display: inline-block; height: 6px; min-width: 0; border-radius: 3px; background: #d989a8; }
.trend-bar.install { background: #83b5c5; }
.list-panel { min-height: 300px; }
.rank-list { display: grid; padding: 4px 17px 8px; }
.rank-list > div { display: grid; grid-template-columns: 24px minmax(0, 1fr) auto; align-items: center; gap: 9px; padding: 10px 0; border-bottom: 1px solid var(--line); }
.rank-list > div:last-child { border-bottom: 0; }
.rank-number { color: var(--sakura-600); font-size: 11px; font-weight: 800; }
.rank-list > div > div { min-width: 0; display: grid; gap: 3px; }
.rank-list strong { overflow: hidden; color: var(--ink-800); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.rank-list small, .rank-list em { color: var(--ink-500); font-size: 10px; font-style: normal; }
.rank-list em.danger { color: #c64d61; }
.error-section { overflow: hidden; }
.section-heading { border-bottom: 0; }
.analytics-filter-bar { margin: 0; border: 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--surface-muted); }
.analytics-filter-bar :deep(.el-input) { min-width: 240px; flex: 1; }
.analytics-filter-bar :deep(.el-select) { width: 180px; }
.analytics-filter-bar :deep(.el-checkbox) { margin: 0 4px; }
.error-table-wrap { min-width: 0; overflow-x: auto; }
.error-table-wrap :deep(.el-table) { min-width: 875px; }
.error-cell { display: flex; min-width: 0; align-items: flex-start; gap: 9px; }
.severity-icon { display: grid; flex: 0 0 30px; width: 30px; height: 30px; place-items: center; border-radius: 7px; font-size: 15px; }
.severity-icon.tone-danger { color: #b63f58; background: #ffe8ed; }
.severity-icon.tone-warning { color: #a97224; background: #fff1d9; }
.error-cell > div { min-width: 0; display: grid; gap: 3px; }
.error-cell strong { overflow: hidden; color: var(--ink-900); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.error-cell small { overflow: hidden; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.table-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 16px; border-top: 1px solid var(--line); }
.table-footer > span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 1320px) { .analytics-metrics { grid-template-columns: repeat(3, minmax(150px, 1fr)); } }
@media (max-width: 900px) {
  .analytics-hero { align-items: flex-start; flex-direction: column; }
  .hero-controls { width: 100%; }
  .hero-controls :deep(.el-select) { flex: 1; }
  .analytics-grid { grid-template-columns: 1fr; }
  .analytics-filter-bar { align-items: stretch; flex-wrap: wrap; }
  .analytics-filter-bar :deep(.el-input) { flex: 1 1 100%; }
}
@media (max-width: 620px) {
  .analytics-metrics { grid-template-columns: 1fr 1fr; }
  .performance-list { grid-template-columns: 1fr 1fr; }
  .performance-list div:last-child { grid-column: 1 / -1; }
  .table-footer { align-items: flex-start; flex-direction: column; }
}
</style>
