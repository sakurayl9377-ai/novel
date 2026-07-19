<script setup lang="ts">
import {
  DocumentChecked,
  Lock,
  Refresh,
  Search,
  User,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { getRaceRound } from '@/services/race-operations';
import type { RaceRoundDetailResponse } from '@/types/race-operations';
import { formatDateTime } from '@/utils/format';
import {
  formatRaceDuration,
  raceBetStatusLabel,
  raceBetStatusTone,
  raceIntegrityLabel,
  raceRoundStatusLabel,
  raceRoundStatusTone,
} from '@/utils/race-operations';

const props = defineProps<{
  modelValue: boolean;
  roundId: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
}>();

const loading = ref(false);
const detail = ref<RaceRoundDetailResponse | null>(null);
const activeTab = ref('overview');
const query = reactive({
  betQ: '',
  betStatus: '',
  horseIndex: '' as number | '',
  page: 1,
  pageSize: 20,
});

const item = computed(() => detail.value?.item || null);
const winnerName = computed(() => {
  if (!item.value || item.value.winnerIndex < 0) return '结算后公开';
  return String(item.value.horses[item.value.winnerIndex]?.name || `#${item.value.winnerIndex + 1}`);
});

watch(
  () => [props.modelValue, props.roundId],
  ([open]) => {
    if (!open || !props.roundId) return;
    Object.assign(query, { betQ: '', betStatus: '', horseIndex: '', page: 1, pageSize: 20 });
    activeTab.value = 'overview';
    void load();
  },
  { immediate: true },
);

async function load(): Promise<void> {
  loading.value = true;
  try {
    detail.value = await getRaceRound(props.roundId, query);
  } catch (error) {
    ElMessage.error(errorMessage(error, '轮次详情加载失败'));
  } finally {
    loading.value = false;
  }
}

function searchBets(): void {
  query.page = 1;
  void load();
}

function resetBetFilters(): void {
  Object.assign(query, { betQ: '', betStatus: '', horseIndex: '', page: 1 });
  void load();
}

function changeBetPage(page: number): void {
  query.page = page;
  void load();
}

function changeBetPageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void load();
}

function timeFromMs(value: number): string {
  return value ? formatDateTime(new Date(value).toISOString()) : '—';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(980px, 98vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="item" class="detail-heading">
        <span class="round-mark">#{{ item.id }}</span>
        <div><span>RACE ROUND · RULE V{{ item.rulesVersion }}</span><h2>{{ item.roundCode || `轮次 ${item.id}` }}</h2><p>{{ formatDateTime(item.createdAt) }} · {{ item.participants }} 位参与者</p></div>
        <ElTag :type="raceRoundStatusTone(item.status)" effect="plain">{{ raceRoundStatusLabel(item.status) }}</ElTag>
      </div>
    </template>

    <div v-loading="loading" class="detail-body">
      <template v-if="detail && item">
        <div class="detail-actions">
          <div class="integrity-state">
            <ElIcon><DocumentChecked v-if="item.integrity.status === 'healthy'" /><WarningFilled v-else /></ElIcon>
            <span><strong>{{ raceIntegrityLabel(item.integrity.status) }}</strong><small>{{ item.integrity.checks }} 项自动核验</small></span>
          </div>
          <ElButton :icon="Refresh" @click="load">刷新</ElButton>
        </div>

        <section class="detail-metrics">
          <div><span>下注笔数</span><strong>{{ item.betCount.toLocaleString() }}</strong><small>{{ item.participants }} 位参与者</small></div>
          <div><span>投注总额</span><strong>{{ item.totalStaked.toLocaleString() }}</strong><small>樱花币</small></div>
          <div><span>返还总额</span><strong>{{ item.totalPayout.toLocaleString() }}</strong><small>樱花币</small></div>
          <div><span>账面净额</span><strong :class="{ negative: item.houseNet < 0 }">{{ item.houseNet.toLocaleString() }}</strong><small>投注减返还</small></div>
          <div><span>冠军</span><strong>{{ winnerName }}</strong><small>{{ item.winnerIndex < 0 ? '结算前隐藏' : `马匹 #${item.winnerIndex + 1}` }}</small></div>
        </section>

        <ElAlert
          v-for="issue in item.integrity.issues"
          :key="issue.code"
          :title="issue.message"
          :type="issue.severity === 'error' ? 'error' : 'warning'"
          :closable="false"
          show-icon
        />

        <ElTabs v-model="activeTab" class="detail-tabs">
          <ElTabPane name="overview" label="轮次概览">
            <section class="phase-band">
              <div><span>阶段开始</span><strong>{{ timeFromMs(item.phaseStartedAt) }}</strong></div>
              <div><span>阶段结束</span><strong>{{ timeFromMs(item.phaseEndsAt) }}</strong></div>
              <div><span>封盘时间</span><strong>{{ formatDateTime(item.lockedAt) }}</strong></div>
              <div><span>结算时间</span><strong>{{ formatDateTime(item.settledAt) }}</strong></div>
            </section>

            <section class="horse-distribution">
              <header><div><strong>马匹投注分布</strong><small>赔率由赛事引擎在封盘时锁定，后台只读。</small></div></header>
              <article v-for="horse in item.horseTotals" :key="horse.index">
                <span class="horse-color" :style="{ background: horse.color || '#d9dde3' }" />
                <div><strong>#{{ horse.index + 1 }} {{ horse.name }}</strong><small>{{ horse.participants }} 位参与者 · {{ horse.betCount }} 笔</small></div>
                <span class="horse-odds">x{{ (item.odds[horse.index] || 0).toFixed(2) }}</span>
                <div class="horse-bar"><i :style="{ width: `${item.totalStaked ? Math.max(2, horse.totalStaked / item.totalStaked * 100) : 0}%` }" /></div>
                <strong class="horse-amount">{{ horse.totalStaked.toLocaleString() }}</strong>
              </article>
            </section>

            <ElCollapse class="rules-collapse">
              <ElCollapseItem name="rules">
                <template #title><div class="collapse-title"><div><strong>赛事规则快照</strong><small>该轮次按规则版本 {{ detail.rules.version }} 执行</small></div><ElTag v-if="detail.rules.legacy" type="warning" effect="plain">历史规则</ElTag></div></template>
                <dl class="rules-grid">
                  <div><dt>投注阶段</dt><dd>{{ formatRaceDuration(detail.rules.phases.bettingSeconds) }}</dd></div>
                  <div><dt>封盘阶段</dt><dd>{{ formatRaceDuration(detail.rules.phases.lockedSeconds) }}</dd></div>
                  <div><dt>比赛阶段</dt><dd>{{ formatRaceDuration(detail.rules.phases.racingSeconds) }}</dd></div>
                  <div><dt>结果展示</dt><dd>{{ formatRaceDuration(detail.rules.phases.resultSeconds) }}</dd></div>
                  <div><dt>单马限额</dt><dd>{{ detail.rules.limits.perHorse.toLocaleString() }}</dd></div>
                  <div><dt>单轮限额</dt><dd>{{ detail.rules.limits.perRound.toLocaleString() }}</dd></div>
                  <div><dt>每日限额</dt><dd>{{ detail.rules.limits.perDay.toLocaleString() }}</dd></div>
                  <div><dt>返还系数</dt><dd>{{ Math.round(detail.rules.payoutRate * 100) }}%</dd></div>
                </dl>
              </ElCollapseItem>
            </ElCollapse>
          </ElTabPane>

          <ElTabPane name="bets" :label="`下注明细 ${detail.bets.total}`">
            <section class="bet-toolbar">
              <ElInput v-model="query.betQ" clearable :prefix-icon="Search" placeholder="用户昵称、邮箱或 ID" @keyup.enter="searchBets" @clear="searchBets" />
              <ElSelect v-model="query.betStatus" clearable placeholder="全部状态" @change="searchBets">
                <ElOption v-for="status in detail.options.betStatuses" :key="status" :label="raceBetStatusLabel(status)" :value="status" />
              </ElSelect>
              <ElSelect v-model="query.horseIndex" clearable placeholder="全部马匹" @change="searchBets">
                <ElOption v-for="horse in item.horseTotals" :key="horse.index" :label="`#${horse.index + 1} ${horse.name}`" :value="horse.index" />
              </ElSelect>
              <ElButton :icon="Search" @click="searchBets">查询</ElButton>
              <ElButton text @click="resetBetFilters">清空</ElButton>
            </section>
            <section class="bet-table">
              <ElTable :data="detail.bets.items" row-key="id" empty-text="没有符合条件的下注记录">
                <ElTableColumn label="用户" min-width="210"><template #default="{ row }"><div class="user-cell"><span><ElIcon><User /></ElIcon></span><div><strong>{{ row.user.nickname || `用户 ${row.user.id}` }}</strong><small>{{ row.user.email }}</small></div></div></template></ElTableColumn>
                <ElTableColumn label="马匹" min-width="135"><template #default="{ row }">#{{ row.horseIndex + 1 }} {{ item.horseTotals[row.horseIndex]?.name || '' }}</template></ElTableColumn>
                <ElTableColumn label="投注" min-width="90" align="right"><template #default="{ row }">{{ row.amount.toLocaleString() }}</template></ElTableColumn>
                <ElTableColumn label="锁定赔率" min-width="95" align="right"><template #default="{ row }">x{{ row.odds.toFixed(2) }}</template></ElTableColumn>
                <ElTableColumn label="返还" min-width="90" align="right"><template #default="{ row }">{{ row.payout.toLocaleString() }}</template></ElTableColumn>
                <ElTableColumn label="状态" min-width="95"><template #default="{ row }"><ElTag :type="raceBetStatusTone(row.status)" effect="plain">{{ raceBetStatusLabel(row.status) }}</ElTag></template></ElTableColumn>
                <ElTableColumn label="时间" min-width="120"><template #default="{ row }">{{ formatDateTime(row.createdAt) }}</template></ElTableColumn>
              </ElTable>
              <div v-if="detail.bets.total" class="table-pagination"><span>共 {{ detail.bets.total }} 笔</span><ElPagination background layout="sizes, prev, pager, next" :current-page="query.page" :page-size="query.pageSize" :page-sizes="[10, 20, 50]" :total="detail.bets.total" @current-change="changeBetPage" @size-change="changeBetPageSize" /></div>
            </section>
          </ElTabPane>

          <ElTabPane name="fairness" label="公平核验">
            <section class="fairness-panel">
              <header><ElIcon><Lock /></ElIcon><div><strong>Seed Commit / Reveal</strong><small>承诺值在轮次创建时保存并锁定，种子只在结算完成后公开。</small></div></header>
              <dl>
                <div><dt>算法</dt><dd>{{ item.fairness.algorithm }}</dd></div>
                <div><dt>承诺值</dt><dd class="hash-value">{{ item.fairness.seedCommit || '缺失' }}</dd></div>
                <div><dt>公开种子</dt><dd class="hash-value">{{ item.fairness.seedReveal || '结算前隐藏' }}</dd></div>
                <div><dt>核验结果</dt><dd><ElTag :type="item.fairness.revealVerified === false ? 'danger' : item.fairness.revealVerified === true ? 'success' : 'info'" effect="plain">{{ item.fairness.revealVerified === true ? '承诺值匹配' : item.fairness.revealVerified === false ? '承诺值不匹配' : '等待结算公开' }}</ElTag></dd></div>
              </dl>
              <ElAlert title="后台没有改冠军、改赔率、改种子或强制结算入口" description="赛事阶段、赛果与返还全部由自动赛事引擎处理；此页面仅用于读取持久化状态和核对一致性。" type="info" :closable="false" show-icon />
            </section>
          </ElTabPane>
        </ElTabs>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.detail-heading { width: 100%; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 11px; }
.round-mark { width: 44px; height: 44px; display: grid; place-items: center; border-radius: 8px; color: var(--sakura-700); background: var(--sakura-100); font-size: 11px; font-weight: 800; }
.detail-heading > div { min-width: 0; }
.detail-heading > div > span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .08em; }
.detail-heading h2 { overflow: hidden; margin: 3px 0 2px; color: var(--ink-900); font-size: 18px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.detail-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.detail-body { display: grid; gap: 13px; min-height: 300px; }
.detail-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.integrity-state { display: flex; align-items: center; gap: 8px; }
.integrity-state > .el-icon { color: #32785e; font-size: 19px; }
.integrity-state span { display: grid; gap: 2px; }
.integrity-state strong { color: var(--ink-900); font-size: 11px; }
.integrity-state small { color: var(--ink-500); font-size: 9px; }
.detail-metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.detail-metrics > div { min-width: 0; display: grid; gap: 4px; padding: 13px; border-right: 1px solid var(--line); }
.detail-metrics > div:last-child { border-right: 0; }
.detail-metrics span, .detail-metrics small { color: var(--ink-500); font-size: 9px; }
.detail-metrics strong { overflow: hidden; color: var(--ink-900); font-size: 17px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.detail-metrics strong.negative { color: #b44b61; }
.detail-tabs { margin-top: 2px; }
.phase-band { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); margin-bottom: 13px; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.phase-band div { display: grid; gap: 4px; padding: 12px; border-right: 1px solid var(--line); }
.phase-band div:last-child { border-right: 0; }
.phase-band span { color: var(--ink-500); font-size: 9px; }
.phase-band strong { color: var(--ink-900); font-size: 11px; }
.horse-distribution, .rules-collapse, .bet-table, .fairness-panel { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.horse-distribution > header { padding: 14px 15px 10px; border-bottom: 1px solid var(--line); }
.horse-distribution header div { display: grid; gap: 3px; }
.horse-distribution header strong { color: var(--ink-900); font-size: 12px; }
.horse-distribution header small { color: var(--ink-500); font-size: 9px; }
.horse-distribution article { display: grid; grid-template-columns: auto minmax(145px, .8fr) 60px minmax(100px, 1fr) 80px; align-items: center; gap: 10px; min-height: 52px; padding: 8px 14px; border-bottom: 1px solid var(--line); }
.horse-distribution article:last-child { border-bottom: 0; }
.horse-color { width: 9px; height: 28px; border-radius: 4px; }
.horse-distribution article > div:nth-child(2) { min-width: 0; display: grid; gap: 2px; }
.horse-distribution article > div:nth-child(2) strong { overflow: hidden; color: var(--ink-900); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.horse-distribution article > div:nth-child(2) small { color: var(--ink-500); font-size: 9px; }
.horse-odds { color: var(--ink-700); font-size: 10px; text-align: right; }
.horse-bar { height: 7px; overflow: hidden; border-radius: 4px; background: #edf0f2; }
.horse-bar i { height: 100%; display: block; border-radius: inherit; background: #d77694; }
.horse-amount { color: var(--ink-900); font-size: 11px; text-align: right; }
.rules-collapse { margin-top: 13px; }
.rules-collapse :deep(.el-collapse-item__header) { min-height: 52px; height: auto; padding: 8px 14px; }
.rules-collapse :deep(.el-collapse-item__content) { padding: 0 14px 14px; }
.collapse-title { width: calc(100% - 18px); display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.collapse-title > div { display: grid; gap: 2px; }
.collapse-title strong { color: var(--ink-900); font-size: 11px; }
.collapse-title small { color: var(--ink-500); font-size: 9px; }
.rules-grid { margin: 0; display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); }
.rules-grid div { padding: 10px; border: 1px solid var(--line); border-right: 0; }
.rules-grid div:nth-child(4n) { border-right: 1px solid var(--line); }
.rules-grid dt { color: var(--ink-500); font-size: 9px; }
.rules-grid dd { margin: 4px 0 0; color: var(--ink-900); font-size: 11px; font-weight: 700; }
.bet-toolbar { display: grid; grid-template-columns: minmax(180px, 1fr) 130px 160px auto auto; gap: 8px; margin-bottom: 11px; }
.bet-table { overflow: hidden; }
.user-cell { min-width: 0; display: flex; align-items: center; gap: 8px; }
.user-cell > span { width: 28px; height: 28px; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-50); }
.user-cell > div { min-width: 0; }
.user-cell strong, .user-cell small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.user-cell strong { color: var(--ink-900); font-size: 10px; }
.user-cell small { color: var(--ink-500); font-size: 9px; }
.table-pagination { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 14px; border-top: 1px solid var(--line); }
.table-pagination > span { color: var(--ink-500); font-size: 9px; }
.fairness-panel { display: grid; gap: 14px; padding: 16px; }
.fairness-panel > header { display: flex; align-items: flex-start; gap: 9px; }
.fairness-panel > header > .el-icon { margin-top: 2px; color: #39769b; }
.fairness-panel header div { display: grid; gap: 3px; }
.fairness-panel header strong { color: var(--ink-900); font-size: 13px; }
.fairness-panel header small { color: var(--ink-500); font-size: 10px; }
.fairness-panel dl { margin: 0; display: grid; border: 1px solid var(--line); border-radius: 7px; overflow: hidden; }
.fairness-panel dl div { display: grid; grid-template-columns: 120px minmax(0, 1fr); border-bottom: 1px solid var(--line); }
.fairness-panel dl div:last-child { border-bottom: 0; }
.fairness-panel dt, .fairness-panel dd { margin: 0; padding: 10px 12px; font-size: 10px; }
.fairness-panel dt { color: var(--ink-500); background: var(--surface-muted); }
.fairness-panel dd { color: var(--ink-900); }
.hash-value { overflow-wrap: anywhere; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
@media (max-width: 700px) {
  .detail-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-metrics > div { border-bottom: 1px solid var(--line); }
  .phase-band { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .horse-distribution article { grid-template-columns: auto minmax(0, 1fr) 55px; }
  .horse-bar { grid-column: 2; }
  .horse-amount { grid-column: 3; }
  .rules-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .rules-grid div:nth-child(2n) { border-right: 1px solid var(--line); }
  .bet-toolbar { grid-template-columns: 1fr 1fr; }
  .bet-toolbar > :first-child { grid-column: 1 / -1; }
}
@media (max-width: 460px) {
  .detail-metrics, .phase-band, .rules-grid, .bet-toolbar { grid-template-columns: 1fr; }
  .bet-toolbar > :first-child { grid-column: 1; }
}
</style>
