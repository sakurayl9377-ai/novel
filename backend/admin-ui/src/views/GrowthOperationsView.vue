<script setup lang="ts">
import {
  Calendar,
  Coin,
  DataAnalysis,
  DocumentChecked,
  EditPen,
  Filter,
  Histogram,
  Plus,
  Promotion,
  Refresh,
  Search,
  StarFilled,
  Tickets,
  TrendCharts,
  User,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import CampaignDetailDrawer from '@/components/growth-operations/CampaignDetailDrawer.vue';
import CampaignEditorDrawer from '@/components/growth-operations/CampaignEditorDrawer.vue';
import CampaignStatusDialog from '@/components/growth-operations/CampaignStatusDialog.vue';
import RankingControlDialog from '@/components/growth-operations/RankingControlDialog.vue';
import MetricCard from '@/components/MetricCard.vue';
import {
  getGrowthCampaign,
  getGrowthCampaigns,
  getGrowthOperationsWorkbench,
  getGrowthRankings,
} from '@/services/growth-operations';
import type {
  CampaignDetailResponse,
  CampaignListResponse,
  CampaignStatus,
  CampaignSummary,
  CatalogSearchItem,
  GrowthContentType,
  GrowthOperationOptions,
  GrowthOperationsWorkbenchResponse,
  GrowthRankingsResponse,
  RankingBoardItem,
  RankingControl,
  RankingMetric,
  RankingPeriod,
} from '@/types/growth-operations';
import { formatDateTime } from '@/utils/format';
import {
  campaignAudienceLabel,
  campaignEditable,
  campaignStatusLabel,
  campaignStatusTone,
  campaignTransitionLabel,
  formatRate,
  growthContentTypeLabel,
  growthEventShortLabel,
  growthOperationActionLabel,
  rankingMetricLabel,
  rankingPeriodLabel,
  rankingScopeLabel,
} from '@/utils/growth-operations';

type WorkspaceTab = 'overview' | 'rankings' | 'campaigns';

const loadingOverview = ref(false);
const loadingRankings = ref(false);
const loadingCampaigns = ref(false);
const initialized = ref(false);
const activeTab = ref<WorkspaceTab>('overview');
const overview = ref<GrowthOperationsWorkbenchResponse>(emptyOverview());
const rankings = ref<GrowthRankingsResponse>(emptyRankings());
const campaigns = ref<CampaignListResponse>(emptyCampaigns());

const overviewQuery = reactive({ days: 7, contentType: '' as GrowthContentType });
const rankingQuery = reactive({
  period: 'weekly' as RankingPeriod,
  metric: 'hot' as RankingMetric,
  contentType: '' as GrowthContentType,
  limit: 50,
});
const campaignQuery = reactive({
  q: '',
  status: '' as '' | CampaignStatus,
  page: 1,
  pageSize: 20,
});
const overviewOpen = ref(['content']);
const rankingOpen = ref(['controls']);

const rankingDialogOpen = ref(false);
const rankingCurrent = ref<RankingControl | null>(null);
const rankingInitialContent = ref<CatalogSearchItem | null>(null);

const campaignEditorOpen = ref(false);
const editingCampaign = ref<CampaignSummary | null>(null);
const campaignDetailOpen = ref(false);
const campaignDetailId = ref(0);
const campaignDetailRefreshKey = ref(0);
const statusDialogOpen = ref(false);
const statusDetail = ref<CampaignDetailResponse | null>(null);
const statusTarget = ref<CampaignStatus | null>(null);

const options = computed<GrowthOperationOptions>(() =>
  overview.value.options.periods.length
    ? overview.value.options
    : rankings.value.options.periods.length
      ? rankings.value.options
      : campaigns.value.options,
);
const campaignFilterCount = computed(() => [campaignQuery.q, campaignQuery.status].filter(Boolean).length);
const currentRankingControls = computed(() => rankings.value.controls.filter(
  (item) => item.rankingKey === rankings.value.rankingKey,
));
const funnelMaximum = computed(() => Math.max(1, ...overview.value.funnel.steps.map((step) => step.actors)));

onMounted(async () => {
  await Promise.allSettled([loadOverview(), loadRankings(), loadCampaigns()]);
  initialized.value = true;
});

async function loadOverview(): Promise<void> {
  loadingOverview.value = true;
  try {
    overview.value = await getGrowthOperationsWorkbench(overviewQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, '增长概览加载失败'));
  } finally {
    loadingOverview.value = false;
  }
}

async function loadRankings(): Promise<void> {
  loadingRankings.value = true;
  try {
    rankings.value = await getGrowthRankings(rankingQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, '榜单规则加载失败'));
  } finally {
    loadingRankings.value = false;
  }
}

async function loadCampaigns(): Promise<void> {
  loadingCampaigns.value = true;
  try {
    campaigns.value = await getGrowthCampaigns(campaignQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动列表加载失败'));
  } finally {
    loadingCampaigns.value = false;
  }
}

function switchTab(tab: string | number): void {
  activeTab.value = String(tab) as WorkspaceTab;
}

function searchCampaigns(): void {
  campaignQuery.page = 1;
  void loadCampaigns();
}

function resetCampaignFilters(): void {
  Object.assign(campaignQuery, { q: '', status: '', page: 1 });
  void loadCampaigns();
}

function filterCampaignStatus(status: '' | CampaignStatus): void {
  campaignQuery.status = campaignQuery.status === status ? '' : status;
  campaignQuery.page = 1;
  void loadCampaigns();
}

function openRankingControl(control: RankingControl | null, content: RankingBoardItem['content'] | null = null): void {
  rankingCurrent.value = control;
  rankingInitialContent.value = content ? {
    stableKey: content.stableKey,
    contentType: content.contentType,
    title: content.title,
    author: content.author,
    coverUrl: content.coverUrl,
    status: 'active',
  } : null;
  rankingDialogOpen.value = true;
}

function openBoardControl(value: unknown): void {
  const item = value as RankingBoardItem;
  const control = rankings.value.controls.find((entry) =>
    entry.contentKey === item.content.stableKey && entry.rankingKey === rankings.value.rankingKey,
  ) || null;
  openRankingControl(control, item.content);
}

function rankingControlFor(value: unknown): RankingControl | null {
  const item = value as RankingBoardItem;
  return rankings.value.controls.find((entry) =>
    entry.contentKey === item.content.stableKey && entry.rankingKey === rankings.value.rankingKey,
  ) || null;
}

async function afterRankingChanged(): Promise<void> {
  await loadRankings();
}

function openCreateCampaign(): void {
  editingCampaign.value = null;
  campaignEditorOpen.value = true;
}

function openEditCampaign(value: unknown): void {
  const item = value as CampaignSummary;
  if (!campaignEditable(item.status)) {
    ElMessage.warning('活动需要先暂停，才能修改配置');
    return;
  }
  editingCampaign.value = item;
  campaignEditorOpen.value = true;
}

function openCampaignDetail(value: unknown): void {
  const item = value as CampaignSummary;
  campaignDetailId.value = item.id;
  campaignDetailOpen.value = true;
}

async function openCampaignStatus(value: unknown, target: CampaignStatus): Promise<void> {
  const item = value as CampaignSummary;
  try {
    statusDetail.value = await getGrowthCampaign(item.id);
    statusTarget.value = target;
    statusDialogOpen.value = true;
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动最新状态加载失败'));
  }
}

function openDetailStatus(target: CampaignStatus, detail: CampaignDetailResponse): void {
  statusDetail.value = detail;
  statusTarget.value = target;
  statusDialogOpen.value = true;
}

async function afterCampaignMutation(detail: CampaignDetailResponse): Promise<void> {
  editingCampaign.value = detail.item;
  statusDetail.value = detail;
  campaignDetailRefreshKey.value += 1;
  await Promise.all([loadCampaigns(), loadOverview()]);
}

function changeCampaignPage(page: number): void {
  campaignQuery.page = page;
  void loadCampaigns();
}

function changeCampaignPageSize(pageSize: number): void {
  campaignQuery.pageSize = pageSize;
  campaignQuery.page = 1;
  void loadCampaigns();
}

function rankingControlMode(control: RankingControl): string {
  if (control.pinned) return '置顶';
  if (control.excluded) return '排除';
  return control.manualWeight ? `权重 ${control.manualWeight > 0 ? '+' : ''}${control.manualWeight}` : '自然排序';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyOptions(): GrowthOperationOptions {
  return {
    periods: [], metrics: [], contentTypes: [], rankingScopes: [],
    campaignStatuses: [], audiencePresets: [], taskEvents: [],
  };
}

function emptyOverview(): GrowthOperationsWorkbenchResponse {
  return {
    generatedAt: '', days: 7, contentType: '',
    funnel: { days: 7, steps: [], content: [], retention: [] },
    totals: { behaviorEvents: 0, activeUsers30d: 0, activeCampaigns: 0, rewardClaims: 0, rewardPoints: 0, rewardCoins: 0 },
    options: emptyOptions(),
  };
}

function emptyRankings(): GrowthRankingsResponse {
  return {
    generatedAt: '', period: 'weekly', metric: 'hot', contentType: '', rankingKey: 'weekly_hot',
    items: [], controls: [], events: [], options: emptyOptions(),
  };
}

function emptyCampaigns(): CampaignListResponse {
  return {
    generatedAt: '', page: 1, pageSize: 20, total: 0, items: [],
    summary: { total: 0, draft: 0, active: 0, paused: 0, ended: 0, pendingClaims: 0 },
    options: emptyOptions(),
  };
}
</script>

<template>
  <div class="page-stack growth-ops-page">
    <section class="growth-hero">
      <div class="hero-copy">
        <span class="eyebrow">GROWTH OPERATIONS</span>
        <h2>用真实行为看转化，用受控规则做运营</h2>
        <p>漏斗数据保持只读；榜单与活动的每次人工调整都需要原因、版本校验和审计记录。</p>
      </div>
      <div class="hero-state">
        <span><ElIcon><DocumentChecked /></ElIcon></span>
        <div><strong>增长写入已受控</strong><small>{{ campaigns.summary.active }} 个活动进行中 · {{ rankings.controls.length }} 条当前关联规则</small></div>
      </div>
    </section>

    <nav class="workspace-tabs" aria-label="增长运营视图">
      <button :class="{ active: activeTab === 'overview' }" @click="switchTab('overview')"><ElIcon><DataAnalysis /></ElIcon><span>转化概览</span></button>
      <button :class="{ active: activeTab === 'rankings' }" @click="switchTab('rankings')"><ElIcon><Histogram /></ElIcon><span>榜单规则</span></button>
      <button :class="{ active: activeTab === 'campaigns' }" @click="switchTab('campaigns')"><ElIcon><Promotion /></ElIcon><span>活动运营</span></button>
    </nav>

    <template v-if="activeTab === 'overview'">
      <section class="view-toolbar">
        <div><strong>内容转化</strong><span>{{ overview.days }} 天窗口 · {{ growthContentTypeLabel(overview.contentType) }}</span></div>
        <div>
          <ElSelect v-model="overviewQuery.days" class="short-select" @change="loadOverview">
            <ElOption label="近 7 天" :value="7" /><ElOption label="近 14 天" :value="14" /><ElOption label="近 30 天" :value="30" /><ElOption label="近 90 天" :value="90" />
          </ElSelect>
          <ElSelect v-model="overviewQuery.contentType" clearable placeholder="全部内容" @change="loadOverview">
            <ElOption v-for="type in options.contentTypes" :key="type" :label="growthContentTypeLabel(type)" :value="type" />
          </ElSelect>
          <ElButton :icon="Refresh" :loading="loadingOverview" @click="loadOverview">刷新</ElButton>
        </div>
      </section>

      <section class="metric-grid growth-metrics" v-loading="loadingOverview && !initialized">
        <MetricCard label="行为事件" :value="overview.totals.behaviorEvents.toLocaleString()" :icon="TrendCharts" hint="已通过去重与频率上限" />
        <MetricCard label="30 天活跃" :value="overview.totals.activeUsers30d.toLocaleString()" :icon="User" hint="有真实内容行为的用户" />
        <MetricCard label="进行中活动" :value="overview.totals.activeCampaigns" :icon="Promotion" hint="当前对用户可见" :tone="overview.totals.activeCampaigns ? 'success' : undefined" />
        <MetricCard label="奖励领取" :value="overview.totals.rewardClaims.toLocaleString()" :icon="Tickets" hint="不可重复领取记录" />
        <MetricCard label="发放成长值" :value="overview.totals.rewardPoints.toLocaleString()" :icon="StarFilled" hint="活动奖励累计" />
        <MetricCard label="发放樱花币" :value="overview.totals.rewardCoins.toLocaleString()" :icon="Coin" hint="活动奖励累计" />
      </section>

      <section v-loading="loadingOverview" class="funnel-section">
        <header class="section-heading compact"><div><span>BEHAVIOR FUNNEL</span><h3>从曝光到收藏的去重用户转化</h3><p>每一步人数来自行为聚合，不受人工榜单权重影响。</p></div></header>
        <div class="funnel-flow">
          <article v-for="(step, index) in overview.funnel.steps" :key="step.event">
            <div class="funnel-label"><span>{{ index + 1 }}</span><strong>{{ growthEventShortLabel(step.event) }}</strong><small>{{ step.events.toLocaleString() }} 次事件</small></div>
            <div class="funnel-bar"><i :style="{ width: `${Math.max(step.actors ? 5 : 0, (step.actors / funnelMaximum) * 100)}%` }" /></div>
            <div class="funnel-value"><strong>{{ step.actors.toLocaleString() }}</strong><small>{{ index ? `${formatRate(step.conversionFromPrevious)} 上一步转化` : '去重用户' }}</small></div>
          </article>
          <ElEmpty v-if="!overview.funnel.steps.length" :image-size="64" description="当前时间范围还没有行为数据" />
        </div>
      </section>

      <ElCollapse v-model="overviewOpen" class="analysis-collapse">
        <ElCollapseItem name="content">
          <template #title><div class="collapse-title"><div><strong>内容转化明细</strong><small>快速定位高曝光低打开、或高开始低完成的作品</small></div><ElTag effect="plain">{{ overview.funnel.content.length }} 项</ElTag></div></template>
          <ElTable :data="overview.funnel.content" row-key="contentKey" empty-text="暂无内容转化数据">
            <ElTableColumn label="内容" min-width="230"><template #default="{ row }"><div class="content-cell"><span>{{ growthContentTypeLabel(row.contentType) }}</span><div><strong>{{ row.title }}</strong><small>{{ row.contentKey }}</small></div></div></template></ElTableColumn>
            <ElTableColumn prop="exposures" label="曝光用户" min-width="100" align="right" />
            <ElTableColumn prop="opens" label="打开用户" min-width="100" align="right" />
            <ElTableColumn label="打开率" min-width="100" align="right"><template #default="{ row }"><b>{{ formatRate(row.openRate) }}</b></template></ElTableColumn>
            <ElTableColumn prop="starts" label="开始用户" min-width="100" align="right" />
            <ElTableColumn prop="completes" label="完成人数" min-width="100" align="right" />
            <ElTableColumn label="完成率" min-width="100" align="right"><template #default="{ row }"><b>{{ formatRate(row.completionRate) }}</b></template></ElTableColumn>
          </ElTable>
        </ElCollapseItem>
        <ElCollapseItem name="retention">
          <template #title><div class="collapse-title"><div><strong>注册留存队列</strong><small>按注册日期观察次日与 7 日内容行为留存</small></div><ElTag effect="plain">{{ overview.funnel.retention.length }} 组</ElTag></div></template>
          <ElTable :data="overview.funnel.retention" empty-text="暂无可计算的留存队列">
            <ElTableColumn prop="cohortDate" label="注册日期" min-width="120" />
            <ElTableColumn prop="cohortSize" label="注册用户" min-width="110" align="right" />
            <ElTableColumn label="次日活跃" min-width="130" align="right"><template #default="{ row }">{{ row.day1 }} · <b>{{ formatRate(row.day1Rate) }}</b></template></ElTableColumn>
            <ElTableColumn label="7 日活跃" min-width="130" align="right"><template #default="{ row }">{{ row.day7 }} · <b>{{ formatRate(row.day7Rate) }}</b></template></ElTableColumn>
          </ElTable>
        </ElCollapseItem>
      </ElCollapse>
    </template>

    <template v-else-if="activeTab === 'rankings'">
      <section class="view-toolbar ranking-toolbar">
        <div><strong>{{ rankingPeriodLabel(rankings.period) }} · {{ rankingMetricLabel(rankings.metric) }}</strong><span>{{ rankings.items.length }} 条当前结果 · {{ currentRankingControls.length }} 条精确范围规则</span></div>
        <div>
          <ElSegmented v-model="rankingQuery.period" :options="[{ label: '日榜', value: 'daily' }, { label: '周榜', value: 'weekly' }]" @change="loadRankings" />
          <ElSelect v-model="rankingQuery.metric" @change="loadRankings"><ElOption v-for="metric in options.metrics" :key="metric" :label="rankingMetricLabel(metric)" :value="metric" /></ElSelect>
          <ElSelect v-model="rankingQuery.contentType" clearable placeholder="全部内容" @change="loadRankings"><ElOption v-for="type in options.contentTypes" :key="type" :label="growthContentTypeLabel(type)" :value="type" /></ElSelect>
          <ElButton :icon="Refresh" :loading="loadingRankings" @click="loadRankings">刷新</ElButton>
          <ElButton type="primary" :icon="Plus" @click="openRankingControl(null)">添加规则</ElButton>
        </div>
      </section>

      <section v-loading="loadingRankings" class="ranking-board">
        <header class="section-heading compact"><div><span>LIVE RESULT</span><h3>当前榜单结果</h3><p>分数来自真实行为信号；人工规则在右侧明确标识。</p></div></header>
        <ElTable :data="rankings.items" row-key="content.stableKey" empty-text="当前范围没有可排行内容">
          <ElTableColumn label="#" width="62" align="center"><template #default="{ row }"><span class="rank-number" :class="{ top: row.rank <= 3 }">{{ row.rank }}</span></template></ElTableColumn>
          <ElTableColumn label="内容" min-width="260"><template #default="{ row }"><div class="rank-content"><img v-if="row.content.coverUrl" :src="row.content.coverUrl" alt="" /><span v-else>{{ growthContentTypeLabel(row.content.contentType).slice(0, 1) }}</span><div><strong>{{ row.content.title }}</strong><small>{{ growthContentTypeLabel(row.content.contentType) }} · {{ row.content.author || row.content.stableKey }}</small></div></div></template></ElTableColumn>
          <ElTableColumn label="综合分" min-width="100" align="right"><template #default="{ row }"><strong class="score-value">{{ Math.round(row.score).toLocaleString() }}</strong></template></ElTableColumn>
          <ElTableColumn label="开始 / 完成" min-width="130" align="right"><template #default="{ row }">{{ row.signals.starts }} / {{ row.signals.completes }}</template></ElTableColumn>
          <ElTableColumn label="收藏" min-width="85" align="right"><template #default="{ row }">{{ row.signals.favorites }}</template></ElTableColumn>
          <ElTableColumn label="完成率" min-width="95" align="right"><template #default="{ row }">{{ formatRate(row.signals.completionRate) }}</template></ElTableColumn>
          <ElTableColumn label="人工规则" min-width="130"><template #default="{ row }"><ElTag v-if="rankingControlFor(row)" :type="rankingControlFor(row)?.pinned ? 'warning' : rankingControlFor(row)?.excluded ? 'danger' : 'info'" effect="plain">{{ rankingControlMode(rankingControlFor(row)!) }}</ElTag><span v-else class="natural-label">自然排序</span></template></ElTableColumn>
          <ElTableColumn label="操作" width="76" fixed="right" align="center"><template #default="{ row }"><ElTooltip content="配置该内容的排行规则"><ElButton circle :icon="EditPen" aria-label="配置排行规则" @click="openBoardControl(row)" /></ElTooltip></template></ElTableColumn>
        </ElTable>
      </section>

      <ElCollapse v-model="rankingOpen" class="analysis-collapse">
        <ElCollapseItem name="controls">
          <template #title><div class="collapse-title"><div><strong>生效中的人工规则</strong><small>同时展示全局、指标级与当前榜单精确范围规则</small></div><ElTag effect="plain">{{ rankings.controls.length }} 条</ElTag></div></template>
          <div class="control-list">
            <article v-for="control in rankings.controls" :key="`${control.rankingKey}:${control.contentKey}`">
              <img v-if="control.coverUrl" :src="control.coverUrl" alt="" /><span v-else><ElIcon><Histogram /></ElIcon></span>
              <div class="control-main"><strong>{{ control.title }}</strong><small>{{ rankingScopeLabel(control.rankingKey) }} · {{ growthContentTypeLabel(control.contentType) }}</small><p>{{ control.note }}</p></div>
              <ElTag :type="control.pinned ? 'warning' : control.excluded ? 'danger' : 'info'" effect="plain">{{ rankingControlMode(control) }}</ElTag>
              <div class="control-admin"><span>版本 {{ control.revision }}</span><small>{{ control.admin.nickname || control.admin.email }} · {{ formatDateTime(control.updatedAt) }}</small></div>
              <ElButton circle :icon="EditPen" aria-label="编辑规则" @click="openRankingControl(control)" />
            </article>
            <ElEmpty v-if="!rankings.controls.length" :image-size="64" description="当前榜单没有人工规则" />
          </div>
        </ElCollapseItem>
        <ElCollapseItem name="audit">
          <template #title><div class="collapse-title"><div><strong>最近规则审计</strong><small>创建、修改与移除都会保留操作人与原因</small></div><ElTag effect="plain">{{ rankings.events.length }} 条</ElTag></div></template>
          <div class="audit-list"><article v-for="event in rankings.events" :key="event.id"><span><ElIcon><DocumentChecked /></ElIcon></span><div><strong>{{ growthOperationActionLabel(event.action) }}</strong><p>{{ event.note }}</p><small>{{ event.admin.nickname || event.admin.email }} · {{ formatDateTime(event.createdAt) }}</small></div></article></div>
        </ElCollapseItem>
      </ElCollapse>
    </template>

    <template v-else>
      <section class="metric-grid campaign-metrics">
        <MetricCard label="活动总数" :value="campaigns.summary.total" :icon="Promotion" hint="历史活动完整保留" />
        <MetricCard label="进行中" :value="campaigns.summary.active" :icon="TrendCharts" hint="当前对用户可见" tone="success" />
        <MetricCard label="待完善草稿" :value="campaigns.summary.draft" :icon="Tickets" hint="尚未启用" />
        <MetricCard label="已暂停" :value="campaigns.summary.paused" :icon="WarningFilled" hint="可编辑或恢复版本" tone="warning" />
        <MetricCard label="已结束" :value="campaigns.summary.ended" :icon="DocumentChecked" hint="不可恢复" />
        <MetricCard label="完成待领取" :value="campaigns.summary.pendingClaims" :icon="Coin" hint="已完成但尚未领取" :tone="campaigns.summary.pendingClaims ? 'warning' : undefined" />
      </section>

      <section class="campaign-toolbar">
        <div class="search-box"><ElInput v-model="campaignQuery.q" clearable :prefix-icon="Search" placeholder="活动名称、标识或说明" @keyup.enter="searchCampaigns" @clear="searchCampaigns" /><ElButton :icon="Search" @click="searchCampaigns">查询</ElButton></div>
        <div class="filter-actions"><ElTag v-if="campaignFilterCount" type="info" effect="plain"><ElIcon><Filter /></ElIcon>{{ campaignFilterCount }} 个筛选条件</ElTag><ElButton v-if="campaignFilterCount" text @click="resetCampaignFilters">清空筛选</ElButton><ElButton :icon="Refresh" :loading="loadingCampaigns" @click="loadCampaigns">刷新</ElButton><ElButton type="primary" :icon="Plus" @click="openCreateCampaign">创建活动草稿</ElButton></div>
      </section>

      <section class="status-strip">
        <button :class="{ active: !campaignQuery.status }" @click="filterCampaignStatus('')"><span>全部</span><strong>{{ campaigns.summary.total }}</strong></button>
        <button v-for="status in options.campaignStatuses" :key="status" :class="{ active: campaignQuery.status === status }" @click="filterCampaignStatus(status)"><span>{{ campaignStatusLabel(status) }}</span><strong>{{ campaigns.summary[status] }}</strong></button>
      </section>

      <section v-loading="loadingCampaigns" class="campaign-table">
        <ElTable :data="campaigns.items" row-key="id" empty-text="没有符合条件的活动" @row-dblclick="openCampaignDetail">
          <ElTableColumn label="活动" min-width="300"><template #default="{ row }"><div class="campaign-cell"><img v-if="row.bannerUrl" :src="row.bannerUrl" alt="" /><span v-else><ElIcon><Promotion /></ElIcon></span><div><strong>{{ row.title }}</strong><small>{{ row.campaignKey }} · 版本 {{ row.revision }}</small><p>{{ row.description || '未填写活动说明' }}</p></div></div></template></ElTableColumn>
          <ElTableColumn label="状态" min-width="100"><template #default="{ row }"><ElTag :type="campaignStatusTone(row.status)" effect="plain">{{ campaignStatusLabel(row.status) }}</ElTag></template></ElTableColumn>
          <ElTableColumn label="人群" min-width="145"><template #default="{ row }">{{ campaignAudienceLabel(row.audiencePreset) }}</template></ElTableColumn>
          <ElTableColumn label="任务 / 进度" min-width="130" align="right"><template #default="{ row }"><strong>{{ row.activeTaskCount }} / {{ row.progressCount.toLocaleString() }}</strong><small class="table-subline">有效任务 / 进度</small></template></ElTableColumn>
          <ElTableColumn label="已发奖励" min-width="135" align="right"><template #default="{ row }"><strong>{{ row.awardedPoints.toLocaleString() }} / {{ row.awardedCoins.toLocaleString() }}</strong><small class="table-subline">成长值 / 樱花币</small></template></ElTableColumn>
          <ElTableColumn label="活动时间" min-width="150"><template #default="{ row }"><span>{{ formatDateTime(row.startsAt) }}</span><small class="table-subline">至 {{ formatDateTime(row.endsAt) }}</small></template></ElTableColumn>
          <ElTableColumn label="操作" width="148" fixed="right"><template #default="{ row }"><div class="row-actions"><ElTooltip content="查看活动详情"><ElButton circle :icon="View" aria-label="查看活动详情" @click="openCampaignDetail(row)" /></ElTooltip><ElTooltip v-if="campaignEditable(row.status)" content="编辑活动配置"><ElButton circle :icon="EditPen" aria-label="编辑活动" @click="openEditCampaign(row)" /></ElTooltip><ElDropdown v-if="row.status !== 'ended'" trigger="click" @command="openCampaignStatus(row, $event as CampaignStatus)"><ElButton circle :icon="Promotion" aria-label="活动状态操作" /><template #dropdown><ElDropdownMenu><ElDropdownItem v-if="row.status === 'active'" command="paused">暂停活动</ElDropdownItem><ElDropdownItem v-else command="active">启用活动</ElDropdownItem><ElDropdownItem command="ended" divided>结束活动</ElDropdownItem></ElDropdownMenu></template></ElDropdown></div></template></ElTableColumn>
        </ElTable>
        <div v-if="campaigns.total" class="table-pagination"><span>共 {{ campaigns.total }} 个活动</span><ElPagination background layout="sizes, prev, pager, next" :current-page="campaignQuery.page" :page-size="campaignQuery.pageSize" :page-sizes="[10, 20, 50]" :total="campaigns.total" @current-change="changeCampaignPage" @size-change="changeCampaignPageSize" /></div>
      </section>
    </template>

    <RankingControlDialog
      v-model="rankingDialogOpen"
      :current="rankingCurrent"
      :initial-content="rankingInitialContent"
      :controls="rankings.controls"
      :default-scope="rankings.rankingKey"
      :options="options"
      @changed="afterRankingChanged"
      @reload="loadRankings"
    />
    <CampaignEditorDrawer v-model="campaignEditorOpen" :item="editingCampaign" :options="options" @saved="afterCampaignMutation" @reload="loadCampaigns" />
    <CampaignDetailDrawer v-model="campaignDetailOpen" :campaign-id="campaignDetailId" :refresh-key="campaignDetailRefreshKey" @edit="openEditCampaign" @status="openDetailStatus" @changed="afterCampaignMutation" />
    <CampaignStatusDialog v-model="statusDialogOpen" :detail="statusDetail" :target="statusTarget" @saved="afterCampaignMutation" @reload="loadCampaigns" />
  </div>
</template>

<style scoped>
.growth-ops-page { gap: 16px; }
.growth-hero { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 6px 2px 10px; }
.hero-copy { min-width: 0; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { max-width: 780px; margin: 0; color: var(--ink-500); font-size: 13px; line-height: 1.6; }
.hero-state { min-width: 260px; display: flex; align-items: center; gap: 10px; padding: 12px 14px; border: 1px solid #cfe5db; border-radius: 8px; background: #f3faf6; }
.hero-state > span { width: 34px; height: 34px; flex: 0 0 34px; display: grid; place-items: center; border-radius: 7px; color: #287258; background: #e1f3e9; }
.hero-state div { min-width: 0; display: grid; gap: 3px; }
.hero-state strong { color: #255f4c; font-size: 12px; }
.hero-state small { color: #5d7d70; font-size: 10px; line-height: 1.4; }
.workspace-tabs { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.workspace-tabs button { min-height: 50px; display: flex; align-items: center; justify-content: center; gap: 8px; border: 0; border-right: 1px solid var(--line); color: var(--ink-500); background: white; font-size: 12px; cursor: pointer; }
.workspace-tabs button:last-child { border-right: 0; }
.workspace-tabs button.active { color: var(--sakura-700); background: var(--sakura-50); font-weight: 800; box-shadow: inset 0 -2px var(--sakura-500); }
.view-toolbar, .campaign-toolbar { min-height: 58px; display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 10px 14px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.view-toolbar > div:first-child { min-width: 0; display: grid; gap: 3px; }
.view-toolbar > div:first-child strong { color: var(--ink-900); font-size: 13px; }
.view-toolbar > div:first-child span { color: var(--ink-500); font-size: 10px; }
.view-toolbar > div:last-child, .filter-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.view-toolbar .el-select { width: 150px; }
.view-toolbar .short-select { width: 110px; }
.growth-metrics, .campaign-metrics { grid-template-columns: repeat(6, minmax(135px, 1fr)); gap: 10px; }
.growth-metrics :deep(.metric-card), .campaign-metrics :deep(.metric-card) { min-height: 126px; padding: 15px; }
.funnel-section, .ranking-board, .campaign-table { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.section-heading.compact { padding: 16px 17px 12px; border-bottom: 1px solid var(--line); }
.section-heading.compact span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.section-heading.compact h3 { margin: 4px 0 3px; color: var(--ink-900); font-size: 16px; letter-spacing: 0; }
.section-heading.compact p { margin: 0; color: var(--ink-500); font-size: 10px; }
.funnel-flow { display: grid; padding: 5px 17px 13px; }
.funnel-flow article { display: grid; grid-template-columns: 180px minmax(150px, 1fr) 150px; align-items: center; gap: 15px; min-height: 64px; border-bottom: 1px solid var(--line); }
.funnel-flow article:last-child { border-bottom: 0; }
.funnel-label { display: grid; grid-template-columns: 28px minmax(0, 1fr); align-items: center; gap: 2px 9px; }
.funnel-label > span { width: 28px; height: 28px; grid-row: 1 / span 2; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-100); font-size: 10px; font-weight: 800; }
.funnel-label strong { color: var(--ink-900); font-size: 12px; }
.funnel-label small { color: var(--ink-500); font-size: 9px; }
.funnel-bar { height: 8px; overflow: hidden; border-radius: 4px; background: #f0edf1; }
.funnel-bar i { height: 100%; display: block; border-radius: inherit; background: linear-gradient(90deg, var(--sakura-400), #e5a45f); }
.funnel-value { min-width: 0; display: grid; justify-items: end; gap: 2px; }
.funnel-value strong { color: var(--ink-900); font-size: 16px; letter-spacing: 0; }
.funnel-value small { color: var(--ink-500); font-size: 9px; }
.analysis-collapse { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.analysis-collapse :deep(.el-collapse-item__header) { min-height: 58px; height: auto; padding: 9px 16px; }
.analysis-collapse :deep(.el-collapse-item__content) { padding: 0 16px 15px; }
.collapse-title { width: calc(100% - 18px); display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.collapse-title > div { min-width: 0; display: grid; gap: 3px; }
.collapse-title strong { color: var(--ink-900); font-size: 12px; }
.collapse-title small { color: var(--ink-500); font-size: 9px; }
.content-cell { min-width: 0; display: flex; align-items: center; gap: 9px; }
.content-cell > span { padding: 4px 6px; border-radius: 5px; color: var(--sakura-700); background: var(--sakura-50); font-size: 9px; }
.content-cell > div { min-width: 0; display: grid; gap: 2px; }
.content-cell strong, .content-cell small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.content-cell strong { color: var(--ink-900); font-size: 11px; }
.content-cell small { color: var(--ink-500); font-size: 9px; }
.rank-number { width: 28px; height: 28px; display: grid; place-items: center; margin: auto; border-radius: 7px; color: var(--ink-600); background: var(--surface-muted); font-size: 11px; font-weight: 800; }
.rank-number.top { color: #8a5c16; background: #fff0cf; }
.rank-content { min-width: 0; display: flex; align-items: center; gap: 9px; }
.rank-content > img, .rank-content > span { width: 34px; height: 44px; flex: 0 0 34px; display: grid; place-items: center; border-radius: 5px; object-fit: cover; color: var(--sakura-700); background: var(--sakura-50); font-size: 10px; font-weight: 800; }
.rank-content > div { min-width: 0; display: grid; gap: 2px; }
.rank-content strong, .rank-content small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.rank-content strong { color: var(--ink-900); font-size: 11px; }
.rank-content small { color: var(--ink-500); font-size: 9px; }
.score-value { color: var(--ink-900); font-size: 13px; letter-spacing: 0; }
.natural-label { color: var(--ink-400); font-size: 10px; }
.control-list article { display: grid; grid-template-columns: auto minmax(180px, 1fr) auto minmax(145px, .6fr) auto; align-items: center; gap: 11px; padding: 12px 2px; border-bottom: 1px solid var(--line); }
.control-list article > img, .control-list article > span { width: 32px; height: 40px; display: grid; place-items: center; border-radius: 5px; object-fit: cover; color: var(--ink-500); background: var(--surface-muted); }
.control-main { min-width: 0; }
.control-main strong { color: var(--ink-900); font-size: 11px; }
.control-main small, .control-admin span, .control-admin small { display: block; color: var(--ink-500); font-size: 9px; }
.control-main p { overflow: hidden; margin: 3px 0 0; color: var(--ink-700); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.control-admin { display: grid; gap: 3px; text-align: right; }
.audit-list { display: grid; }
.audit-list article { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 10px; padding: 11px 2px; border-bottom: 1px solid var(--line); }
.audit-list article > span { width: 30px; height: 30px; display: grid; place-items: center; border-radius: 7px; color: #58697d; background: #edf1f5; }
.audit-list strong { color: var(--ink-900); font-size: 11px; }
.audit-list p { margin: 3px 0; color: var(--ink-700); font-size: 10px; }
.audit-list small { color: var(--ink-500); font-size: 9px; }
.campaign-toolbar .search-box { min-width: 300px; display: flex; gap: 7px; }
.campaign-toolbar .search-box .el-input { width: min(390px, 35vw); }
.status-strip { display: grid; grid-template-columns: repeat(5, minmax(100px, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.status-strip button { min-height: 54px; display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 0 15px; border: 0; border-right: 1px solid var(--line); color: var(--ink-500); background: white; cursor: pointer; }
.status-strip button:last-child { border-right: 0; }
.status-strip button.active { color: var(--sakura-700); background: var(--sakura-50); }
.status-strip span { font-size: 10px; }
.status-strip strong { color: inherit; font-size: 17px; letter-spacing: 0; }
.campaign-cell { min-width: 0; display: flex; align-items: center; gap: 10px; }
.campaign-cell > img, .campaign-cell > span { width: 72px; height: 44px; flex: 0 0 72px; display: grid; place-items: center; border-radius: 6px; object-fit: cover; color: var(--sakura-600); background: var(--sakura-50); }
.campaign-cell > div { min-width: 0; }
.campaign-cell strong, .campaign-cell small, .campaign-cell p { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.campaign-cell strong { color: var(--ink-900); font-size: 11px; }
.campaign-cell small { margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.campaign-cell p { margin: 3px 0 0; color: var(--ink-600); font-size: 9px; }
.table-subline { display: block; margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.row-actions { display: flex; gap: 5px; }
.table-pagination { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 15px; border-top: 1px solid var(--line); }
.table-pagination > span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 1100px) {
  .growth-metrics, .campaign-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); }
  .ranking-toolbar { align-items: flex-start; flex-direction: column; }
  .ranking-toolbar > div:last-child { justify-content: flex-start; }
}
@media (max-width: 760px) {
  .growth-hero, .view-toolbar, .campaign-toolbar { align-items: flex-start; flex-direction: column; }
  .hero-state { width: 100%; min-width: 0; }
  .view-toolbar > div:last-child, .filter-actions { width: 100%; justify-content: flex-start; }
  .funnel-flow article { grid-template-columns: 120px minmax(80px, 1fr); gap: 10px; }
  .funnel-value { grid-column: 2; justify-items: start; padding-bottom: 8px; }
  .control-list article { grid-template-columns: auto minmax(0, 1fr) auto; }
  .control-list article > .el-tag, .control-admin { grid-column: 2; text-align: left; }
  .control-list article > .el-button { grid-column: 3; grid-row: 1 / span 3; }
  .campaign-toolbar .search-box { width: 100%; min-width: 0; }
  .campaign-toolbar .search-box .el-input { width: 100%; }
  .status-strip { grid-template-columns: repeat(2, minmax(100px, 1fr)); }
  .status-strip button { border-bottom: 1px solid var(--line); }
}
@media (max-width: 520px) {
  .hero-copy h2 { font-size: 21px; }
  .workspace-tabs button { min-height: 46px; }
  .growth-metrics, .campaign-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .view-toolbar .el-select, .view-toolbar .short-select { width: 100%; }
  .view-toolbar > div:last-child > * { flex: 1 1 130px; }
  .funnel-flow article { grid-template-columns: 1fr; padding: 9px 0; }
  .funnel-value { grid-column: 1; }
}
</style>
