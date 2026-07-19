<script setup lang="ts">
import {
  Coin,
  DataAnalysis,
  DocumentChecked,
  EditPen,
  Filter,
  Lock,
  Medal,
  Plus,
  Promotion,
  Refresh,
  Search,
  Stopwatch,
  Tickets,
  Trophy,
  User,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import RaceRoundDetailDrawer from '@/components/race-operations/RaceRoundDetailDrawer.vue';
import RaceSeasonDetailDrawer from '@/components/race-operations/RaceSeasonDetailDrawer.vue';
import RaceSeasonEditorDrawer from '@/components/race-operations/RaceSeasonEditorDrawer.vue';
import RaceSeasonStatusDialog from '@/components/race-operations/RaceSeasonStatusDialog.vue';
import {
  getRaceRounds,
  getRaceSeasons,
  getRaceWorkbench,
  getResponsibleGamingOverview,
} from '@/services/race-operations';
import type {
  RaceIntegrityStatus,
  RaceOperationOptions,
  RaceRoundListResponse,
  RaceRoundStatus,
  RaceRoundSummary,
  RaceSeasonDetailResponse,
  RaceSeasonListResponse,
  RaceSeasonStatus,
  RaceSeasonSummary,
  RaceWorkbenchResponse,
  ResponsibleGamingOverview,
} from '@/types/race-operations';
import { formatDateTime } from '@/utils/format';
import {
  formatRaceDuration,
  raceIntegrityLabel,
  raceIntegrityTone,
  raceNoticeLabel,
  raceRoundStatusLabel,
  raceRoundStatusTone,
  raceSeasonEditable,
  raceSeasonStatusLabel,
  raceSeasonStatusTone,
  raceTierLabel,
} from '@/utils/race-operations';

type WorkspaceTab = 'overview' | 'rounds' | 'seasons' | 'responsible';
type SeasonAction = RaceSeasonStatus | 'finalize';

const loadingOverview = ref(false);
const loadingRounds = ref(false);
const loadingSeasons = ref(false);
const loadingResponsible = ref(false);
const activeTab = ref<WorkspaceTab>('overview');
const overview = ref<RaceWorkbenchResponse>(emptyWorkbench());
const rounds = ref<RaceRoundListResponse>(emptyRounds());
const seasons = ref<RaceSeasonListResponse>(emptySeasons());
const responsible = ref<ResponsibleGamingOverview>(emptyResponsible());

const roundQuery = reactive({
  q: '',
  status: '' as '' | RaceRoundStatus,
  integrity: '' as '' | RaceIntegrityStatus,
  page: 1,
  pageSize: 20,
});
const seasonQuery = reactive({
  q: '',
  status: '' as '' | RaceSeasonStatus,
  page: 1,
  pageSize: 20,
});
const rulesOpen = ref(['boundaries']);

const roundDetailOpen = ref(false);
const roundDetailId = ref(0);
const seasonEditorOpen = ref(false);
const editingSeason = ref<RaceSeasonSummary | null>(null);
const seasonDetailOpen = ref(false);
const seasonDetailId = ref(0);
const seasonDetailRefreshKey = ref(0);
const statusDialogOpen = ref(false);
const statusDetail = ref<RaceSeasonDetailResponse | null>(null);
const statusTarget = ref<SeasonAction | null>(null);

const options = computed<RaceOperationOptions>(() => (
  overview.value.options.roundStatuses.length
    ? overview.value.options
    : rounds.value.options.roundStatuses.length
      ? rounds.value.options
      : seasons.value.options
));
const roundFilterCount = computed(() => [roundQuery.q, roundQuery.status, roundQuery.integrity].filter(Boolean).length);
const seasonFilterCount = computed(() => [seasonQuery.q, seasonQuery.status].filter(Boolean).length);

onMounted(async () => {
  await Promise.allSettled([loadOverview(), loadRounds(), loadSeasons(), loadResponsible()]);
});

async function loadOverview(): Promise<void> {
  loadingOverview.value = true;
  try {
    overview.value = await getRaceWorkbench();
    responsible.value = overview.value.responsibleGaming;
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛马概览加载失败'));
  } finally {
    loadingOverview.value = false;
  }
}

async function loadRounds(): Promise<void> {
  loadingRounds.value = true;
  try {
    rounds.value = await getRaceRounds(roundQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, '轮次列表加载失败'));
  } finally {
    loadingRounds.value = false;
  }
}

async function loadSeasons(): Promise<void> {
  loadingSeasons.value = true;
  try {
    seasons.value = await getRaceSeasons(seasonQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛季列表加载失败'));
  } finally {
    loadingSeasons.value = false;
  }
}

async function loadResponsible(): Promise<void> {
  loadingResponsible.value = true;
  try {
    responsible.value = await getResponsibleGamingOverview();
  } catch (error) {
    ElMessage.error(errorMessage(error, '理性参与汇总加载失败'));
  } finally {
    loadingResponsible.value = false;
  }
}

function switchTab(tab: WorkspaceTab): void {
  activeTab.value = tab;
}

function searchRounds(): void {
  roundQuery.page = 1;
  void loadRounds();
}

function resetRoundFilters(): void {
  Object.assign(roundQuery, { q: '', status: '', integrity: '', page: 1 });
  void loadRounds();
}

function changeRoundPage(page: number): void {
  roundQuery.page = page;
  void loadRounds();
}

function changeRoundPageSize(pageSize: number): void {
  roundQuery.pageSize = pageSize;
  roundQuery.page = 1;
  void loadRounds();
}

function searchSeasons(): void {
  seasonQuery.page = 1;
  void loadSeasons();
}

function resetSeasonFilters(): void {
  Object.assign(seasonQuery, { q: '', status: '', page: 1 });
  void loadSeasons();
}

function filterSeasonStatus(status: '' | RaceSeasonStatus): void {
  seasonQuery.status = seasonQuery.status === status ? '' : status;
  seasonQuery.page = 1;
  void loadSeasons();
}

function changeSeasonPage(page: number): void {
  seasonQuery.page = page;
  void loadSeasons();
}

function changeSeasonPageSize(pageSize: number): void {
  seasonQuery.pageSize = pageSize;
  seasonQuery.page = 1;
  void loadSeasons();
}

function openRound(value: RaceRoundSummary): void {
  roundDetailId.value = value.id;
  roundDetailOpen.value = true;
}

function openRoundRow(value: unknown): void {
  openRound(value as RaceRoundSummary);
}

function openCreateSeason(): void {
  editingSeason.value = null;
  seasonEditorOpen.value = true;
}

function openEditSeason(value: RaceSeasonSummary): void {
  if (!raceSeasonEditable(value.status)) {
    ElMessage.warning('进行中的赛季需要先暂停，才能修改配置');
    return;
  }
  editingSeason.value = value;
  seasonEditorOpen.value = true;
}

function openEditSeasonRow(value: unknown): void {
  openEditSeason(value as RaceSeasonSummary);
}

function openSeason(value: RaceSeasonSummary): void {
  seasonDetailId.value = value.id;
  seasonDetailOpen.value = true;
}

function openSeasonRow(value: unknown): void {
  openSeason(value as RaceSeasonSummary);
}

async function afterSeasonMutation(value: RaceSeasonDetailResponse): Promise<void> {
  seasonDetailId.value = value.item.id;
  seasonDetailRefreshKey.value += 1;
  await Promise.allSettled([loadOverview(), loadSeasons()]);
}

function openDetailStatus(target: SeasonAction, detail: RaceSeasonDetailResponse): void {
  statusTarget.value = target;
  statusDetail.value = detail;
  statusDialogOpen.value = true;
}

function phaseEndLabel(round: RaceRoundSummary): string {
  return round.phaseEndsAt ? formatDateTime(new Date(round.phaseEndsAt).toISOString()) : '—';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyOptions(): RaceOperationOptions {
  return {
    roundStatuses: [], betStatuses: [], integrityStatuses: [], seasonStatuses: [],
    seasonMetrics: [], taskStatuses: [], rewardStatuses: [], tiers: [],
  };
}

function emptyResponsible(): ResponsibleGamingOverview {
  return {
    configuredUsers: 0,
    activeCooldowns: 0,
    activeSelfExclusions: 0,
    customBetLimits: 0,
    customLossLimits: 0,
    today: { participants: 0, totalBet: 0, totalPayout: 0, aggregateLoss: 0, usersAtReminderThreshold: 0 },
    notices: [],
    policy: { mode: 'aggregate_read_only', userControlsMutableByAdmin: false },
  };
}

function emptyWorkbench(): RaceWorkbenchResponse {
  return {
    generatedAt: '', currentRound: null,
    service: { leaseKey: 'horse-race-ticker', active: false, ownerId: '', leaseUntil: 0, updatedAt: '' },
    finance24h: { betCount: 0, participants: 0, totalStaked: 0, totalPayout: 0, houseNet: 0 },
    rounds: { total: 0, betting: 0, locked: 0, racing: 0, settled: 0, recentWarnings: 0, recentErrors: 0 },
    season: null, responsibleGaming: emptyResponsible(),
    rules: {
      version: 2, legacy: false,
      schedule: { timezone: 'Asia/Hong_Kong', opensAt: '06:00', closesAt: '24:00' },
      phases: { bettingSeconds: 240, lockedSeconds: 20, racingSeconds: 60, resultSeconds: 40 },
      limits: { minBet: 1, perHorse: 1000, perRound: 2000, perDay: 20000 },
      payoutRate: 0.9, operatorControlsResult: false,
    },
    options: emptyOptions(),
  };
}

function emptyRounds(): RaceRoundListResponse {
  return { generatedAt: '', page: 1, pageSize: 20, total: 0, items: [], options: emptyOptions() };
}

function emptySeasons(): RaceSeasonListResponse {
  return {
    generatedAt: '', page: 1, pageSize: 20, total: 0, items: [],
    summary: { total: 0, draft: 0, active: 0, paused: 0, ended: 0 },
    options: emptyOptions(),
  };
}
</script>

<template>
  <div class="page-stack race-page">
    <section class="race-hero">
      <div class="hero-copy">
        <span class="eyebrow">RACE OPERATIONS</span>
        <h2>赛马运营工作台</h2>
        <p>自动赛事监控、轮次一致性核验、赛季生命周期与奖励预算。</p>
      </div>
      <div class="hero-state" :class="{ idle: !overview.service.active }">
        <span><ElIcon><Promotion /></ElIcon></span>
        <div><strong>{{ overview.service.active ? '自动赛事引擎运行中' : overview.currentRound ? '自动赛事引擎待命' : '当前无运行轮次' }}</strong><small>{{ overview.service.active ? '分布式推进租约已持有' : overview.currentRound ? `${raceRoundStatusLabel(overview.currentRound.status)} · ${overview.currentRound.roundCode}` : '等待开放时段创建新轮次' }}</small></div>
      </div>
    </section>

    <nav class="workspace-tabs" aria-label="赛马运营视图">
      <button :class="{ active: activeTab === 'overview' }" @click="switchTab('overview')"><ElIcon><DataAnalysis /></ElIcon>运营概览</button>
      <button :class="{ active: activeTab === 'rounds' }" @click="switchTab('rounds')"><ElIcon><Stopwatch /></ElIcon>轮次审计</button>
      <button :class="{ active: activeTab === 'seasons' }" @click="switchTab('seasons')"><ElIcon><Trophy /></ElIcon>赛季管理</button>
      <button :class="{ active: activeTab === 'responsible' }" @click="switchTab('responsible')"><ElIcon><Lock /></ElIcon>理性参与</button>
    </nav>

    <template v-if="activeTab === 'overview'">
      <section class="view-toolbar"><div><strong>实时运行状态</strong><span>数据生成于 {{ formatDateTime(overview.generatedAt) }}</span></div><div><ElButton :icon="Refresh" :loading="loadingOverview" @click="loadOverview">刷新</ElButton></div></section>
      <section class="metric-grid race-metrics">
        <MetricCard label="24 小时投注" :value="overview.finance24h.totalStaked" :icon="Coin" :hint="`${overview.finance24h.betCount} 笔下注`" />
        <MetricCard label="24 小时返还" :value="overview.finance24h.totalPayout" :icon="Promotion" hint="樱花币" />
        <MetricCard label="24 小时参与者" :value="overview.finance24h.participants" :icon="User" hint="去重用户" />
        <MetricCard label="历史轮次" :value="overview.rounds.total" :icon="Stopwatch" :hint="`${overview.rounds.settled} 轮已结算`" />
        <MetricCard label="近期异常" :value="overview.rounds.recentErrors" :icon="WarningFilled" :hint="`${overview.rounds.recentWarnings} 项提醒`" :tone="overview.rounds.recentErrors ? 'danger' : overview.rounds.recentWarnings ? 'warning' : 'success'" />
        <MetricCard label="当前赛季" :value="overview.season?.participants || 0" :icon="Trophy" :hint="overview.season?.title || '未启用赛季'" />
      </section>

      <section v-if="overview.currentRound" class="current-round">
        <header><div><span>LIVE ROUND</span><h3>{{ overview.currentRound.roundCode }}</h3><p>规则 v{{ overview.currentRound.rulesVersion }} · 阶段预计 {{ phaseEndLabel(overview.currentRound) }} 结束</p></div><div><ElTag :type="raceRoundStatusTone(overview.currentRound.status)" effect="plain">{{ raceRoundStatusLabel(overview.currentRound.status) }}</ElTag><ElButton :icon="View" @click="openRound(overview.currentRound)">查看轮次</ElButton></div></header>
        <div class="round-stats"><article><span>参与者</span><strong>{{ overview.currentRound.participants }}</strong></article><article><span>下注笔数</span><strong>{{ overview.currentRound.betCount }}</strong></article><article><span>投注总额</span><strong>{{ overview.currentRound.totalStaked.toLocaleString() }}</strong></article><article><span>锁定返还</span><strong>{{ overview.currentRound.totalPayout.toLocaleString() }}</strong></article><article><span>核验</span><ElTag :type="raceIntegrityTone(overview.currentRound.integrity.status)" effect="plain">{{ raceIntegrityLabel(overview.currentRound.integrity.status) }}</ElTag></article></div>
      </section>
      <ElEmpty v-else :image-size="72" description="当前没有赛事轮次" />

      <ElCollapse v-model="rulesOpen" class="rules-collapse">
        <ElCollapseItem name="rules"><template #title><div class="collapse-title"><div><strong>自动赛事规则</strong><small>{{ overview.rules.schedule.timezone }} · 每日 {{ overview.rules.schedule.opensAt }} - {{ overview.rules.schedule.closesAt }}</small></div><ElTag type="info" effect="plain">规则 v{{ overview.rules.version }}</ElTag></div></template><div class="rule-grid"><article><span>投注</span><strong>{{ formatRaceDuration(overview.rules.phases.bettingSeconds) }}</strong></article><article><span>封盘</span><strong>{{ formatRaceDuration(overview.rules.phases.lockedSeconds) }}</strong></article><article><span>比赛</span><strong>{{ formatRaceDuration(overview.rules.phases.racingSeconds) }}</strong></article><article><span>结果展示</span><strong>{{ formatRaceDuration(overview.rules.phases.resultSeconds) }}</strong></article><article><span>单轮限额</span><strong>{{ overview.rules.limits.perRound }}</strong></article><article><span>每日限额</span><strong>{{ overview.rules.limits.perDay }}</strong></article></div></ElCollapseItem>
        <ElCollapseItem name="boundaries"><template #title><div class="collapse-title"><div><strong>运营权限边界</strong><small>结果控制由自动赛事引擎持有</small></div><ElTag type="success" effect="plain">只读公平审计</ElTag></div></template><section class="boundary-grid"><article><ElIcon><DocumentChecked /></ElIcon><div><strong>可以核验</strong><small>阶段、承诺值、封盘赔率、下注状态、返还金额与最终榜单。</small></div></article><article><ElIcon><Lock /></ElIcon><div><strong>不能干预</strong><small>后台没有修改冠军、赔率、种子、比赛进度或强制结算入口。</small></div></article></section></ElCollapseItem>
      </ElCollapse>
    </template>

    <template v-else-if="activeTab === 'rounds'">
      <section class="filter-toolbar">
        <div class="search-box"><ElInput v-model="roundQuery.q" clearable :prefix-icon="Search" placeholder="轮次编号" @keyup.enter="searchRounds" @clear="searchRounds" /><ElButton :icon="Search" @click="searchRounds">查询</ElButton></div>
        <div class="filter-actions"><ElSelect v-model="roundQuery.status" clearable placeholder="全部阶段" @change="searchRounds"><ElOption v-for="status in options.roundStatuses" :key="status" :label="raceRoundStatusLabel(status)" :value="status" /></ElSelect><ElSelect v-model="roundQuery.integrity" clearable placeholder="全部核验状态" @change="searchRounds"><ElOption v-for="status in options.integrityStatuses" :key="status" :label="raceIntegrityLabel(status)" :value="status" /></ElSelect><ElTag v-if="roundFilterCount" type="info" effect="plain"><ElIcon><Filter /></ElIcon>{{ roundFilterCount }} 个条件</ElTag><ElButton v-if="roundFilterCount" text @click="resetRoundFilters">清空</ElButton><ElButton :icon="Refresh" :loading="loadingRounds" @click="loadRounds">刷新</ElButton></div>
      </section>
      <section v-loading="loadingRounds" class="data-table">
        <ElTable :data="rounds.items" row-key="id" empty-text="没有符合条件的轮次" @row-dblclick="openRoundRow">
          <ElTableColumn label="轮次" min-width="210"><template #default="{ row }"><div class="round-cell"><span>#{{ row.id }}</span><div><strong>{{ row.roundCode || `轮次 ${row.id}` }}</strong><small>规则 v{{ row.rulesVersion }} · {{ formatDateTime(row.createdAt) }}</small></div></div></template></ElTableColumn>
          <ElTableColumn label="阶段" min-width="100"><template #default="{ row }"><ElTag :type="raceRoundStatusTone(row.status)" effect="plain">{{ raceRoundStatusLabel(row.status) }}</ElTag></template></ElTableColumn>
          <ElTableColumn label="参与 / 下注" min-width="110" align="right"><template #default="{ row }"><strong>{{ row.participants }} / {{ row.betCount }}</strong><small class="table-subline">用户 / 笔数</small></template></ElTableColumn>
          <ElTableColumn label="投注 / 返还" min-width="135" align="right"><template #default="{ row }"><strong>{{ row.totalStaked.toLocaleString() }} / {{ row.totalPayout.toLocaleString() }}</strong><small class="table-subline">樱花币</small></template></ElTableColumn>
          <ElTableColumn label="账面净额" min-width="100" align="right"><template #default="{ row }"><span :class="{ positive: row.houseNet > 0, negative: row.houseNet < 0 }">{{ row.houseNet > 0 ? '+' : '' }}{{ row.houseNet.toLocaleString() }}</span></template></ElTableColumn>
          <ElTableColumn label="一致性" min-width="120"><template #default="{ row }"><ElTag :type="raceIntegrityTone(row.integrity.status)" effect="plain">{{ raceIntegrityLabel(row.integrity.status) }}</ElTag><small v-if="row.integrity.errorCount || row.integrity.warningCount" class="table-subline">{{ row.integrity.errorCount }} 异常 · {{ row.integrity.warningCount }} 提醒</small></template></ElTableColumn>
          <ElTableColumn label="操作" width="78" fixed="right"><template #default="{ row }"><ElTooltip content="查看轮次详情"><ElButton circle :icon="View" aria-label="查看轮次" @click="openRoundRow(row)" /></ElTooltip></template></ElTableColumn>
        </ElTable>
        <div v-if="rounds.total" class="table-pagination"><span>共 {{ rounds.total }} 个轮次</span><ElPagination background layout="sizes, prev, pager, next" :current-page="roundQuery.page" :page-size="roundQuery.pageSize" :page-sizes="[10, 20, 50]" :total="rounds.total" @current-change="changeRoundPage" @size-change="changeRoundPageSize" /></div>
      </section>
    </template>

    <template v-else-if="activeTab === 'seasons'">
      <section class="metric-grid season-metrics">
        <MetricCard label="赛季总数" :value="seasons.summary.total" :icon="Trophy" hint="历史配置完整保留" />
        <MetricCard label="进行中" :value="seasons.summary.active" :icon="Promotion" hint="最多一个启用赛季" tone="success" />
        <MetricCard label="草稿" :value="seasons.summary.draft" :icon="Tickets" hint="待配置与复核" />
        <MetricCard label="已暂停" :value="seasons.summary.paused" :icon="WarningFilled" hint="可编辑或结算" tone="warning" />
        <MetricCard label="已结束" :value="seasons.summary.ended" :icon="DocumentChecked" hint="不可重新启用" />
      </section>
      <section class="filter-toolbar">
        <div class="search-box"><ElInput v-model="seasonQuery.q" clearable :prefix-icon="Search" placeholder="赛季名称、标识或说明" @keyup.enter="searchSeasons" @clear="searchSeasons" /><ElButton :icon="Search" @click="searchSeasons">查询</ElButton></div>
        <div class="filter-actions"><ElTag v-if="seasonFilterCount" type="info" effect="plain"><ElIcon><Filter /></ElIcon>{{ seasonFilterCount }} 个条件</ElTag><ElButton v-if="seasonFilterCount" text @click="resetSeasonFilters">清空</ElButton><ElButton :icon="Refresh" :loading="loadingSeasons" @click="loadSeasons">刷新</ElButton><ElButton type="primary" :icon="Plus" @click="openCreateSeason">创建赛季草稿</ElButton></div>
      </section>
      <section class="status-strip"><button :class="{ active: !seasonQuery.status }" @click="filterSeasonStatus('')"><span>全部</span><strong>{{ seasons.summary.total }}</strong></button><button v-for="status in options.seasonStatuses" :key="status" :class="{ active: seasonQuery.status === status }" @click="filterSeasonStatus(status)"><span>{{ raceSeasonStatusLabel(status) }}</span><strong>{{ seasons.summary[status] }}</strong></button></section>
      <section v-loading="loadingSeasons" class="data-table">
        <ElTable :data="seasons.items" row-key="id" empty-text="没有符合条件的赛季" @row-dblclick="openSeasonRow">
          <ElTableColumn label="赛季" min-width="280"><template #default="{ row }"><div class="season-cell"><span><ElIcon><Trophy /></ElIcon></span><div><strong>{{ row.title }}</strong><small>{{ row.seasonKey }} · 版本 {{ row.revision }}</small><p>{{ row.description || '未填写赛季说明' }}</p></div></div></template></ElTableColumn>
          <ElTableColumn label="状态" min-width="100"><template #default="{ row }"><ElTag :type="raceSeasonStatusTone(row.status)" effect="plain">{{ raceSeasonStatusLabel(row.status) }}</ElTag></template></ElTableColumn>
          <ElTableColumn label="参与 / 记录" min-width="115" align="right"><template #default="{ row }"><strong>{{ row.participants }} / {{ row.settlementRecords }}</strong><small class="table-subline">用户 / 结算记录</small></template></ElTableColumn>
          <ElTableColumn label="任务 / 奖励" min-width="110" align="right"><template #default="{ row }"><strong>{{ row.activeTaskCount }} / {{ row.activeRewardCount }}</strong><small class="table-subline">有效配置</small></template></ElTableColumn>
          <ElTableColumn label="赛季时间" min-width="150"><template #default="{ row }"><span>{{ formatDateTime(row.startsAt) }}</span><small class="table-subline">至 {{ formatDateTime(row.endsAt) }}</small></template></ElTableColumn>
          <ElTableColumn label="操作" width="116" fixed="right"><template #default="{ row }"><div class="row-actions"><ElTooltip content="查看赛季详情"><ElButton circle :icon="View" aria-label="查看赛季" @click="openSeasonRow(row)" /></ElTooltip><ElTooltip v-if="raceSeasonEditable(row.status)" content="编辑赛季配置"><ElButton circle :icon="EditPen" aria-label="编辑赛季" @click="openEditSeasonRow(row)" /></ElTooltip></div></template></ElTableColumn>
        </ElTable>
        <div v-if="seasons.total" class="table-pagination"><span>共 {{ seasons.total }} 个赛季</span><ElPagination background layout="sizes, prev, pager, next" :current-page="seasonQuery.page" :page-size="seasonQuery.pageSize" :page-sizes="[10, 20, 50]" :total="seasons.total" @current-change="changeSeasonPage" @size-change="changeSeasonPageSize" /></div>
      </section>
    </template>

    <template v-else>
      <section class="view-toolbar"><div><strong>理性参与汇总</strong><span>仅展示聚合数据，用户自设冷静期与自我排除不能由后台解除</span></div><div><ElButton :icon="Refresh" :loading="loadingResponsible" @click="loadResponsible">刷新</ElButton></div></section>
      <section class="metric-grid responsible-metrics">
        <MetricCard label="冷静期生效" :value="responsible.activeCooldowns" :icon="Stopwatch" hint="当前有效" tone="warning" />
        <MetricCard label="自我排除生效" :value="responsible.activeSelfExclusions" :icon="Lock" hint="当前有效" tone="warning" />
        <MetricCard label="自定义投注限额" :value="responsible.customBetLimits" :icon="Coin" hint="用户主动设置" />
        <MetricCard label="自定义损失限额" :value="responsible.customLossLimits" :icon="WarningFilled" hint="用户主动设置" />
        <MetricCard label="今日参与者" :value="responsible.today.participants" :icon="User" hint="香港自然日" />
        <MetricCard label="达到提醒阈值" :value="responsible.today.usersAtReminderThreshold" :icon="Tickets" hint="仅聚合计数" :tone="responsible.today.usersAtReminderThreshold ? 'warning' : 'success'" />
      </section>
      <section class="responsible-band"><article><span>今日投注</span><strong>{{ responsible.today.totalBet.toLocaleString() }}</strong><small>樱花币</small></article><article><span>今日返还</span><strong>{{ responsible.today.totalPayout.toLocaleString() }}</strong><small>樱花币</small></article><article><span>聚合净损失</span><strong>{{ responsible.today.aggregateLoss.toLocaleString() }}</strong><small>只用于风险观察</small></article><article><span>已配置用户</span><strong>{{ responsible.configuredUsers.toLocaleString() }}</strong><small>至少一项理性参与设置</small></article></section>
      <section class="notice-table"><header><div><strong>近 30 日提醒记录</strong><small>按日期和提醒类型聚合，不展示个人身份</small></div><ElTag type="success" effect="plain"><ElIcon><Lock /></ElIcon>只读</ElTag></header><ElTable :data="responsible.notices" empty-text="近 30 日没有提醒记录"><ElTableColumn prop="noticeDate" label="日期" min-width="120" /><ElTableColumn label="提醒类型" min-width="180"><template #default="{ row }">{{ raceNoticeLabel(row.noticeType) }}</template></ElTableColumn><ElTableColumn prop="count" label="提醒人数" min-width="100" align="right" /><ElTableColumn label="关联金额" min-width="120" align="right"><template #default="{ row }">{{ row.amount.toLocaleString() }}</template></ElTableColumn></ElTable></section>
    </template>

    <RaceRoundDetailDrawer v-model="roundDetailOpen" :round-id="roundDetailId" />
    <RaceSeasonEditorDrawer v-model="seasonEditorOpen" :item="editingSeason" :options="options" @saved="afterSeasonMutation" @reload="loadSeasons" />
    <RaceSeasonDetailDrawer v-model="seasonDetailOpen" :season-id="seasonDetailId" :refresh-key="seasonDetailRefreshKey" @edit="openEditSeason" @status="openDetailStatus" @changed="afterSeasonMutation" />
    <RaceSeasonStatusDialog v-model="statusDialogOpen" :detail="statusDetail" :target="statusTarget" @saved="afterSeasonMutation" @reload="loadSeasons" />
  </div>
</template>

<style scoped>
.race-page { gap: 16px; }
.race-hero { display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 6px 2px 10px; }
.hero-copy { min-width: 0; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; letter-spacing: 0; }
.hero-copy p { margin: 0; color: var(--ink-500); font-size: 13px; }
.hero-state { min-width: 290px; display: flex; align-items: center; gap: 10px; padding: 12px 14px; border: 1px solid #cfe5db; border-radius: 8px; background: #f3faf6; }
.hero-state.idle { border-color: #d9e0e5; background: #f7f9fa; }
.hero-state > span { width: 34px; height: 34px; flex: 0 0 34px; display: grid; place-items: center; border-radius: 7px; color: #287258; background: #e1f3e9; }
.hero-state.idle > span { color: #506978; background: #e7edf1; }
.hero-state div { min-width: 0; display: grid; gap: 3px; }
.hero-state strong { color: #255f4c; font-size: 12px; }
.hero-state.idle strong { color: #425b69; }
.hero-state small { overflow: hidden; color: #5d7d70; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.workspace-tabs { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.workspace-tabs button { min-height: 50px; display: flex; align-items: center; justify-content: center; gap: 8px; border: 0; border-right: 1px solid var(--line); color: var(--ink-500); background: white; font-size: 12px; cursor: pointer; }
.workspace-tabs button:last-child { border-right: 0; }
.workspace-tabs button.active { color: var(--sakura-700); background: var(--sakura-50); font-weight: 800; box-shadow: inset 0 -2px var(--sakura-500); }
.view-toolbar, .filter-toolbar { min-height: 58px; display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 10px 14px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.view-toolbar > div:first-child { min-width: 0; display: grid; gap: 3px; }
.view-toolbar strong { color: var(--ink-900); font-size: 12px; }
.view-toolbar span { color: var(--ink-500); font-size: 9px; }
.race-metrics, .responsible-metrics { grid-template-columns: repeat(6, minmax(135px, 1fr)); gap: 10px; }
.season-metrics { grid-template-columns: repeat(5, minmax(140px, 1fr)); gap: 10px; }
.race-metrics :deep(.metric-card), .season-metrics :deep(.metric-card), .responsible-metrics :deep(.metric-card) { min-height: 124px; padding: 15px; }
.current-round { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.current-round > header { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 15px 17px; border-bottom: 1px solid var(--line); }
.current-round header > div:first-child { min-width: 0; }
.current-round header span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.current-round header h3 { margin: 4px 0 2px; color: var(--ink-900); font-size: 16px; letter-spacing: 0; }
.current-round header p { margin: 0; color: var(--ink-500); font-size: 9px; }
.current-round header > div:last-child { display: flex; align-items: center; gap: 8px; }
.round-stats { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); }
.round-stats article { min-width: 0; display: grid; gap: 5px; padding: 13px 16px; border-right: 1px solid var(--line); }
.round-stats article:last-child { border-right: 0; }
.round-stats span { color: var(--ink-500); font-size: 9px; }
.round-stats strong { color: var(--ink-900); font-size: 16px; letter-spacing: 0; }
.rules-collapse { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.rules-collapse :deep(.el-collapse-item__header) { min-height: 56px; height: auto; padding: 9px 16px; }
.rules-collapse :deep(.el-collapse-item__content) { padding: 0 16px 15px; }
.collapse-title { width: calc(100% - 18px); display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.collapse-title > div { display: grid; gap: 3px; }
.collapse-title strong { color: var(--ink-900); font-size: 12px; }
.collapse-title small { color: var(--ink-500); font-size: 9px; }
.rule-grid { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); }
.rule-grid article { min-width: 0; display: grid; gap: 5px; padding: 11px; border: 1px solid var(--line); border-right: 0; }
.rule-grid article:last-child { border-right: 1px solid var(--line); }
.rule-grid span { color: var(--ink-500); font-size: 9px; }
.rule-grid strong { color: var(--ink-900); font-size: 11px; }
.boundary-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.boundary-grid article { display: flex; align-items: flex-start; gap: 9px; padding: 13px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }
.boundary-grid article > .el-icon { margin-top: 2px; color: #39769b; }
.boundary-grid article div { display: grid; gap: 3px; }
.boundary-grid strong { color: var(--ink-900); font-size: 11px; }
.boundary-grid small { color: var(--ink-500); font-size: 9px; line-height: 1.5; }
.filter-toolbar .search-box { min-width: 280px; display: flex; gap: 7px; }
.filter-toolbar .search-box .el-input { width: min(360px, 32vw); }
.filter-actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; flex-wrap: wrap; }
.filter-actions .el-select { width: 145px; }
.data-table, .notice-table { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.round-cell, .season-cell { min-width: 0; display: flex; align-items: center; gap: 9px; }
.round-cell > span, .season-cell > span { width: 34px; height: 34px; flex: 0 0 34px; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-50); font-size: 9px; font-weight: 800; }
.season-cell > span { color: #89661c; background: #fff1d1; font-size: 15px; }
.round-cell > div, .season-cell > div { min-width: 0; }
.round-cell strong, .round-cell small, .season-cell strong, .season-cell small, .season-cell p { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.round-cell strong, .season-cell strong { color: var(--ink-900); font-size: 11px; }
.round-cell small, .season-cell small { margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.season-cell p { margin: 3px 0 0; color: var(--ink-600); font-size: 9px; }
.table-subline { display: block; margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.positive { color: #2c7a5b; }.negative { color: #b44b61; }
.row-actions { display: flex; gap: 5px; }
.table-pagination { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 15px; border-top: 1px solid var(--line); }
.table-pagination > span { color: var(--ink-500); font-size: 10px; }
.status-strip { display: grid; grid-template-columns: repeat(5, minmax(100px, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.status-strip button { min-height: 54px; display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 0 15px; border: 0; border-right: 1px solid var(--line); color: var(--ink-500); background: white; cursor: pointer; }
.status-strip button:last-child { border-right: 0; }
.status-strip button.active { color: var(--sakura-700); background: var(--sakura-50); }
.status-strip span { font-size: 10px; }.status-strip strong { color: inherit; font-size: 17px; letter-spacing: 0; }
.responsible-band { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.responsible-band article { display: grid; gap: 5px; padding: 14px; border-right: 1px solid var(--line); }
.responsible-band article:last-child { border-right: 0; }
.responsible-band span, .responsible-band small { color: var(--ink-500); font-size: 9px; }
.responsible-band strong { color: var(--ink-900); font-size: 17px; letter-spacing: 0; }
.notice-table > header { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 14px 16px; border-bottom: 1px solid var(--line); }
.notice-table header div { display: grid; gap: 3px; }
.notice-table header strong { color: var(--ink-900); font-size: 12px; }
.notice-table header small { color: var(--ink-500); font-size: 9px; }
@media (max-width: 1100px) {
  .race-metrics, .responsible-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); }
  .season-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); }
  .rule-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
  .rule-grid article:nth-child(3) { border-right: 1px solid var(--line); }
}
@media (max-width: 760px) {
  .race-hero, .view-toolbar, .filter-toolbar { align-items: flex-start; flex-direction: column; }
  .hero-state { width: 100%; min-width: 0; }
  .filter-toolbar .search-box { width: 100%; min-width: 0; }
  .filter-toolbar .search-box .el-input { width: 100%; }
  .filter-actions { width: 100%; justify-content: flex-start; }
  .round-stats, .responsible-band { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .boundary-grid { grid-template-columns: 1fr; }
  .status-strip { grid-template-columns: repeat(2, minmax(100px, 1fr)); }
  .status-strip button { border-bottom: 1px solid var(--line); }
}
@media (max-width: 520px) {
  .hero-copy h2 { font-size: 21px; }
  .workspace-tabs { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .workspace-tabs button { border-bottom: 1px solid var(--line); }
  .race-metrics, .season-metrics, .responsible-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .current-round > header { align-items: flex-start; flex-direction: column; }
  .rule-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .rule-grid article:nth-child(2n) { border-right: 1px solid var(--line); }
  .filter-actions .el-select { width: 100%; }
}
</style>
