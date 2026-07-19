<script setup lang="ts">
import {
  CircleCheck,
  Document,
  Filter,
  Monitor,
  Refresh,
  Search,
  TrendCharts,
  User,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import VersionInstallDrawer from '@/components/versions/VersionInstallDrawer.vue';
import { getVersionWorkbench } from '@/services/versions';
import type {
  VersionActivity,
  VersionInstall,
  VersionWorkbenchResponse,
} from '@/types/versions';
import { formatCompactNumber, formatDateTime, parseServerTime } from '@/utils/format';
import {
  versionInstallFreshness,
  versionPlatformLabel,
  versionPlatformTone,
} from '@/utils/system-operations';

const activityOptions: Array<{ value: VersionActivity; label: string }> = [
  { value: 'all', label: '全部上报' },
  { value: '7d', label: '最近 7 天活跃' },
  { value: '30d', label: '最近 30 天活跃' },
  { value: 'stale', label: '超过 30 天未上报' },
];

const loading = ref(false);
const initialized = ref(false);
const workbench = ref<VersionWorkbenchResponse>(emptyWorkbench());
const selectedInstall = ref<VersionInstall | null>(null);
const detailOpen = ref(false);
const query = reactive({
  q: '',
  versionCode: 0,
  platform: '',
  activity: 'all' as VersionActivity,
  page: 1,
  pageSize: 20,
});

const filterCount = computed(() => [
  query.q,
  query.versionCode,
  query.platform,
  query.activity !== 'all' ? query.activity : '',
].filter(Boolean).length);

const platformOptions = computed(() => workbench.value.platforms.map((item) => item.platform).filter(Boolean));
const versionMaximum = computed(() => Math.max(1, ...workbench.value.versions.map((item) => item.userCount)));
const freshnessState = computed(() => {
  const summary = workbench.value.summary;
  if (!summary.reportingUsers) {
    return { type: 'warning' as const, title: '还没有收到设备上报', detail: '版本覆盖指标暂时没有样本，先确认客户端启动后的上报链路。' };
  }
  const lastSeen = parseServerTime(summary.lastSeenAt);
  const ageDays = lastSeen ? Math.max(0, (Date.now() - lastSeen.getTime()) / 86400000) : Number.POSITIVE_INFINITY;
  if (summary.staleInstalls > 0 || ageDays > 2) {
    return { type: 'warning' as const, title: '版本数据存在滞后设备', detail: `最近一次上报：${formatDateTime(summary.lastSeenAt)}，有 ${formatCompactNumber(summary.staleInstalls)} 个安装超过 30 天未更新。` };
  }
  return { type: 'success' as const, title: '版本上报链路正常', detail: `最近一次上报：${formatDateTime(summary.lastSeenAt)}，当前覆盖 ${formatCompactNumber(summary.reportingUsers)} 个账号。` };
});

onMounted(() => void loadVersions());

async function loadVersions(): Promise<void> {
  loading.value = true;
  try {
    workbench.value = await getVersionWorkbench({
      q: query.q.trim(),
      versionCode: query.versionCode,
      platform: query.platform,
      activity: query.activity,
      page: query.page,
      pageSize: query.pageSize,
    });
  } catch (error) {
    ElMessage.error(errorMessage(error, '版本设备数据加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function applyFilters(): void {
  query.page = 1;
  void loadVersions();
}

function resetFilters(): void {
  Object.assign(query, { q: '', versionCode: 0, platform: '', activity: 'all', page: 1 });
  void loadVersions();
}

function changePage(page: number): void {
  query.page = page;
  void loadVersions();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadVersions();
}

function openDetail(item: VersionInstall): void {
  selectedInstall.value = item;
  detailOpen.value = true;
}

function asInstall(row: unknown): VersionInstall {
  return row as VersionInstall;
}

function versionLabel(versionName: string, versionCode: number): string {
  return `${versionName || '未命名版本'} #${versionCode}`;
}

function versionBarWidth(value: number): string {
  return `${Math.max(4, Math.round((value / versionMaximum.value) * 100))}%`;
}

function percent(value: number): string {
  return `${(Math.max(0, Math.min(1, Number(value || 0))) * 100).toFixed(1)}%`;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): VersionWorkbenchResponse {
  return {
    generatedAt: '',
    page: 1,
    pageSize: 20,
    total: 0,
    filters: { q: '', versionCode: 0, platform: '', activity: 'all' },
    summary: {
      registeredUsers: 0,
      reportingUsers: 0,
      unreportedUsers: 0,
      installs: 0,
      active7dInstalls: 0,
      staleInstalls: 0,
      latestVersionCode: 0,
      latestVersionName: '',
      currentUsers: 0,
      outdatedUsers: 0,
      reportingCoverage: 0,
      upgradeCoverage: 0,
      lastSeenAt: '',
    },
    versions: [],
    platforms: [],
    versionOptions: [],
    items: [],
  };
}
</script>

<template>
  <div class="page-stack system-page versions-page">
    <section class="workbench-hero">
      <div class="hero-copy">
        <span class="eyebrow">CLIENT COVERAGE</span>
        <h2>版本与设备</h2>
        <p>用真实设备上报判断版本覆盖、升级滞后和兼容性风险，不把“注册过账号”误当成“当前在线”。</p>
      </div>
      <div class="hero-controls">
        <ElButton :icon="Refresh" :loading="loading" @click="loadVersions">刷新</ElButton>
      </div>
    </section>

    <ElAlert :title="freshnessState.title" :type="freshnessState.type" :closable="false" show-icon>
      <template #default>{{ freshnessState.detail }}</template>
    </ElAlert>

    <ElSkeleton v-if="!initialized && loading" :rows="9" animated />
    <template v-else>
      <section class="metric-grid version-metrics">
        <MetricCard label="当前版本" :value="workbench.summary.latestVersionName || `#${workbench.summary.latestVersionCode || 0}`" :hint="`版本号 #${workbench.summary.latestVersionCode || 0}`" :icon="Monitor" />
        <MetricCard label="上报覆盖" :value="percent(workbench.summary.reportingCoverage)" :hint="`${formatCompactNumber(workbench.summary.reportingUsers)} / ${formatCompactNumber(workbench.summary.registeredUsers)} 个账号`" :icon="CircleCheck" :tone="workbench.summary.reportingCoverage < 0.7 ? 'warning' : 'success'" />
        <MetricCard label="升级覆盖" :value="percent(workbench.summary.upgradeCoverage)" :hint="`${formatCompactNumber(workbench.summary.outdatedUsers)} 个账号仍在旧版本`" :icon="TrendCharts" :tone="workbench.summary.upgradeCoverage < 0.8 ? 'warning' : 'success'" />
        <MetricCard label="安装记录" :value="formatCompactNumber(workbench.summary.installs)" :hint="`${formatCompactNumber(workbench.summary.active7dInstalls)} 个近 7 天活跃`" :icon="Document" />
        <MetricCard label="长期未上报" :value="formatCompactNumber(workbench.summary.staleInstalls)" hint="超过 30 天" :icon="WarningFilled" :tone="workbench.summary.staleInstalls ? 'warning' : 'success'" />
        <MetricCard label="未上报账号" :value="formatCompactNumber(workbench.summary.unreportedUsers)" hint="没有任何设备记录" :icon="User" />
      </section>

      <section class="system-grid distribution-grid">
        <article class="system-panel">
          <header class="panel-heading">
            <div><span>VERSION MIX</span><h3>版本覆盖</h3><p>按每个账号最近一次设备上报去重</p></div>
            <ElIcon><TrendCharts /></ElIcon>
          </header>
          <div v-if="workbench.versions.length" class="distribution-list">
            <button v-for="item in workbench.versions.slice(0, 8)" :key="`${item.versionCode}-${item.platform}`" type="button" @click="query.versionCode = item.versionCode; applyFilters()">
              <div class="distribution-label"><strong>{{ versionLabel(item.versionName, item.versionCode) }}</strong><small>{{ versionPlatformLabel(item.platform) }} · 最近 {{ formatDateTime(item.lastSeenAt) }}</small></div>
              <div class="distribution-value"><span class="distribution-track"><i :style="{ width: versionBarWidth(item.userCount) }" /></span><b>{{ item.userCount.toLocaleString() }}</b></div>
            </button>
          </div>
          <ElEmpty v-else :image-size="50" description="暂无版本上报" />
        </article>

        <article class="system-panel">
          <header class="panel-heading">
            <div><span>PLATFORM COVERAGE</span><h3>平台与设备</h3><p>点击平台可直接筛选设备记录</p></div>
            <ElIcon><Monitor /></ElIcon>
          </header>
          <div v-if="workbench.platforms.length" class="platform-list">
            <button v-for="item in workbench.platforms" :key="item.platform" type="button" @click="query.platform = query.platform === item.platform ? '' : item.platform; applyFilters()">
              <span class="platform-mark" :class="`tone-${versionPlatformTone(item.platform)}`"><ElIcon><Monitor /></ElIcon></span>
              <div><strong>{{ versionPlatformLabel(item.platform) }}</strong><small>最新版本 #{{ item.latestVersionCode }} · {{ formatDateTime(item.lastSeenAt) }}</small></div>
              <b>{{ item.userCount.toLocaleString() }}</b>
            </button>
          </div>
          <ElEmpty v-else :image-size="50" description="暂无平台上报" />
        </article>
      </section>

      <section class="system-panel table-panel">
        <header class="section-heading">
          <div><span>INSTALL REPORTS</span><h3>设备上报</h3><p>{{ workbench.total.toLocaleString() }} 条安装记录 · 点击行查看账号和环境</p></div>
          <ElTag type="info" effect="plain">{{ activityOptions.find((item) => item.value === query.activity)?.label }}</ElTag>
        </header>
        <div class="filter-bar system-filter-bar">
          <ElInput v-model="query.q" clearable :prefix-icon="Search" placeholder="账号、设备型号、系统或安装标识" @keyup.enter="applyFilters" @clear="applyFilters" />
          <ElSelect v-model="query.versionCode" clearable placeholder="全部版本" @change="applyFilters">
            <ElOption label="全部版本" :value="0" />
            <ElOption v-for="item in workbench.versionOptions" :key="item.versionCode" :label="versionLabel(item.versionName, item.versionCode)" :value="item.versionCode" />
          </ElSelect>
          <ElSelect v-model="query.platform" clearable placeholder="全部平台" @change="applyFilters">
            <ElOption label="全部平台" value="" />
            <ElOption v-for="platform in platformOptions" :key="platform" :label="versionPlatformLabel(platform)" :value="platform" />
          </ElSelect>
          <ElSelect v-model="query.activity" placeholder="活跃度" @change="applyFilters">
            <ElOption v-for="item in activityOptions" :key="item.value" :label="item.label" :value="item.value" />
          </ElSelect>
          <ElButton type="primary" :icon="Search" @click="applyFilters">查询</ElButton>
          <ElButton v-if="filterCount" :icon="Filter" @click="resetFilters">清除 {{ filterCount }}</ElButton>
        </div>
        <div v-loading="loading" class="table-wrap version-table-wrap">
          <ElTable :data="workbench.items" row-key="id" empty-text="当前筛选下没有设备记录" @row-click="(row) => openDetail(asInstall(row))">
            <ElTableColumn label="账号与设备" min-width="300">
              <template #default="{ row }">
                <div class="operation-cell"><span class="operation-icon"><ElIcon><User /></ElIcon></span><div><strong>{{ asInstall(row).user.nickname || `用户 #${asInstall(row).user.id}` }}</strong><small>{{ asInstall(row).deviceModel || '设备型号未记录' }} · {{ asInstall(row).osVersion || '系统未记录' }}</small></div></div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="版本" min-width="150"><template #default="{ row }"><div class="compact-cell"><strong>{{ versionLabel(asInstall(row).versionName, asInstall(row).versionCode) }}</strong><small>{{ asInstall(row).installId }}</small></div></template></ElTableColumn>
            <ElTableColumn label="平台" width="115"><template #default="{ row }"><ElTag :type="versionPlatformTone(asInstall(row).platform)" effect="plain">{{ versionPlatformLabel(asInstall(row).platform) }}</ElTag></template></ElTableColumn>
            <ElTableColumn label="最近上报" width="155"><template #default="{ row }"><div class="compact-cell"><strong :class="{ warning: versionInstallFreshness(asInstall(row)) === 'stale' }">{{ formatDateTime(asInstall(row).lastSeenAt) }}</strong><small>{{ versionInstallFreshness(asInstall(row)) === 'stale' ? '超过 30 天' : '近期有上报' }}</small></div></template></ElTableColumn>
            <ElTableColumn label="来源 IP" width="140"><template #default="{ row }">{{ asInstall(row).lastIp || '—' }}</template></ElTableColumn>
            <ElTableColumn label="查看" width="78" fixed="right"><template #default="{ row }"><ElButton circle :icon="Document" aria-label="查看设备详情" @click.stop="openDetail(asInstall(row))" /></template></ElTableColumn>
          </ElTable>
          <ElEmpty v-if="initialized && !loading && !workbench.items.length" :image-size="60" description="当前筛选下没有设备记录" />
        </div>
        <footer v-if="workbench.total" class="table-footer"><span>第 {{ workbench.page }} 页 · 共 {{ workbench.total.toLocaleString() }} 条</span><ElPagination background layout="sizes, prev, pager, next" :current-page="query.page" :page-size="query.pageSize" :page-sizes="[10, 20, 50]" :total="workbench.total" @current-change="changePage" @size-change="changePageSize" /></footer>
      </section>
    </template>

    <VersionInstallDrawer v-model="detailOpen" :item="selectedInstall" />
  </div>
</template>

<style scoped>
.system-page { gap: 17px; }
.workbench-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid #83b5c5; border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.hero-copy { min-width: 0; }.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; }.hero-copy p { max-width: 780px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }
.hero-controls { display: flex; flex: 0 0 auto; align-items: center; gap: 8px; }
.version-metrics { grid-template-columns: repeat(6, minmax(140px, 1fr)); gap: 10px; }.version-metrics :deep(.metric-card) { min-height: 115px; padding: 14px; }
.system-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }.system-panel { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }
.panel-heading, .section-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 16px 17px; border-bottom: 1px solid var(--line); }.panel-heading > div, .section-heading > div:first-child { min-width: 0; display: grid; gap: 3px; }.panel-heading span, .section-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }.panel-heading h3, .section-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; }.panel-heading p, .section-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }.panel-heading > .el-icon { color: #5f9aaa; font-size: 18px; }
.distribution-list { display: grid; gap: 0; padding: 5px 17px 8px; }.distribution-list button { display: grid; gap: 7px; padding: 11px 0; border: 0; border-bottom: 1px solid var(--line); text-align: left; background: transparent; }.distribution-list button:last-child { border-bottom: 0; }.distribution-list button:hover strong { color: var(--sakura-600); }.distribution-label { display: flex; align-items: center; justify-content: space-between; gap: 10px; }.distribution-label strong { overflow: hidden; color: var(--ink-800); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.distribution-label small { flex: 0 0 auto; color: var(--ink-500); font-size: 9px; }.distribution-value { display: flex; align-items: center; gap: 9px; }.distribution-track { height: 7px; flex: 1; overflow: hidden; border-radius: 4px; background: #f0edf1; }.distribution-track i { display: block; height: 100%; min-width: 3px; border-radius: inherit; background: #83b5c5; }.distribution-value b { width: 42px; color: var(--ink-900); font-size: 12px; text-align: right; }
.platform-list { display: grid; gap: 0; padding: 5px 17px 8px; }.platform-list button { display: grid; grid-template-columns: 34px minmax(0, 1fr) auto; align-items: center; gap: 10px; min-height: 62px; padding: 9px 0; border: 0; border-bottom: 1px solid var(--line); text-align: left; background: transparent; }.platform-list button:last-child { border-bottom: 0; }.platform-list button:hover strong { color: var(--sakura-600); }.platform-list button > div { min-width: 0; display: grid; gap: 4px; }.platform-list strong { color: var(--ink-800); font-size: 12px; }.platform-list small { overflow: hidden; color: var(--ink-500); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }.platform-list b { color: var(--ink-900); font-size: 16px; }.platform-mark { width: 34px; height: 34px; display: grid; place-items: center; border-radius: 8px; }.platform-mark.tone-success { color: #2b7b5b; background: #eaf7f0; }.platform-mark.tone-info { color: #39769b; background: #edf5fa; }.platform-mark.tone-warning { color: #a97224; background: #fff3dc; }
.table-panel { overflow: hidden; }.section-heading { border-bottom: 0; }.filter-bar { display: flex; align-items: center; gap: 8px; padding: 13px 16px; }.system-filter-bar { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: var(--surface-muted); }.system-filter-bar :deep(.el-input) { min-width: 220px; flex: 1; }.system-filter-bar :deep(.el-select) { width: 145px; }.table-wrap { min-width: 0; overflow-x: auto; }.version-table-wrap :deep(.el-table) { min-width: 980px; }
.operation-cell, .compact-cell { min-width: 0; display: flex; align-items: flex-start; gap: 9px; }.operation-cell > div, .compact-cell { display: grid; gap: 3px; }.operation-icon { width: 30px; height: 30px; flex: 0 0 30px; display: grid; place-items: center; border-radius: 7px; color: #39769b; background: #edf5fa; }.operation-cell strong, .compact-cell strong { overflow: hidden; color: var(--ink-900); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.operation-cell small, .compact-cell small { overflow: hidden; color: var(--ink-500); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }.warning { color: #b87921 !important; }.table-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 16px; border-top: 1px solid var(--line); }.table-footer > span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 1320px) { .version-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); } }
@media (max-width: 900px) { .workbench-hero { align-items: flex-start; flex-direction: column; }.hero-controls { width: 100%; }.system-grid { grid-template-columns: 1fr; }.system-filter-bar { align-items: stretch; flex-wrap: wrap; }.system-filter-bar :deep(.el-input) { flex: 1 1 100%; } }
@media (max-width: 620px) { .version-metrics { grid-template-columns: 1fr 1fr; }.distribution-label { align-items: flex-start; flex-direction: column; gap: 3px; }.table-footer { align-items: flex-start; flex-direction: column; } }
</style>
