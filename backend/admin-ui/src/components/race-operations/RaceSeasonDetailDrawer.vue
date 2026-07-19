<script setup lang="ts">
import {
  Delete,
  DocumentChecked,
  EditPen,
  Lock,
  Medal,
  Plus,
  Refresh,
  Tickets,
  Trophy,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import RaceSeasonRewardDialog from '@/components/race-operations/RaceSeasonRewardDialog.vue';
import RaceSeasonTaskDialog from '@/components/race-operations/RaceSeasonTaskDialog.vue';
import { ApiError } from '@/services/api';
import {
  getRaceSeason,
  removeRaceSeasonReward,
  removeRaceSeasonTask,
} from '@/services/race-operations';
import type {
  RaceSeasonDetailResponse,
  RaceSeasonReward,
  RaceSeasonStatus,
  RaceSeasonSummary,
  RaceSeasonTask,
} from '@/types/race-operations';
import { formatDateTime } from '@/utils/format';
import {
  raceMetricLabel,
  raceRewardScopeLabel,
  raceSeasonActionLabel,
  raceSeasonEditable,
  raceSeasonStatusLabel,
  raceSeasonStatusTone,
  raceSeasonTransitionLabel,
  raceTierLabel,
} from '@/utils/race-operations';

type SeasonAction = RaceSeasonStatus | 'finalize';
type RemoveTarget = { kind: 'task'; item: RaceSeasonTask } | { kind: 'reward'; item: RaceSeasonReward };

const props = defineProps<{
  modelValue: boolean;
  seasonId: number;
  refreshKey: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  edit: [item: RaceSeasonSummary];
  status: [target: SeasonAction, detail: RaceSeasonDetailResponse];
  changed: [detail: RaceSeasonDetailResponse];
}>();

const loading = ref(false);
const detail = ref<RaceSeasonDetailResponse | null>(null);
const activeTab = ref('overview');
const leaderboardPage = ref(1);
const leaderboardPageSize = ref(20);
const taskDialogOpen = ref(false);
const editingTask = ref<RaceSeasonTask | null>(null);
const rewardDialogOpen = ref(false);
const editingReward = ref<RaceSeasonReward | null>(null);
const removeDialogOpen = ref(false);
const removeTarget = ref<RemoveTarget | null>(null);
const removeNote = ref('');
const removing = ref(false);

const item = computed(() => detail.value?.item || null);
const editable = computed(() => Boolean(item.value && raceSeasonEditable(item.value.status)));
const structureLocked = computed(() => Boolean(item.value?.participants));

watch(
  () => [props.modelValue, props.seasonId, props.refreshKey],
  ([open]) => {
    if (open && props.seasonId) void load();
  },
  { immediate: true },
);

async function load(): Promise<void> {
  loading.value = true;
  try {
    detail.value = await getRaceSeason(props.seasonId, {
      leaderboardPage: leaderboardPage.value,
      leaderboardPageSize: leaderboardPageSize.value,
    });
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛季详情加载失败'));
  } finally {
    loading.value = false;
  }
}

function afterMutation(value: RaceSeasonDetailResponse): void {
  detail.value = value;
  emit('changed', value);
}

function openTask(task: RaceSeasonTask | null): void {
  editingTask.value = task;
  taskDialogOpen.value = true;
}

function openReward(reward: RaceSeasonReward | null): void {
  editingReward.value = reward;
  rewardDialogOpen.value = true;
}

function openRemove(target: RemoveTarget): void {
  removeTarget.value = target;
  removeNote.value = '';
  removeDialogOpen.value = true;
}

async function remove(): Promise<void> {
  if (!detail.value || !removeTarget.value || removeNote.value.trim().length < 4) {
    ElMessage.warning('请填写具体的移除原因');
    return;
  }
  removing.value = true;
  try {
    const result = removeTarget.value.kind === 'task'
      ? await removeRaceSeasonTask(
        detail.value.item.id,
        removeTarget.value.item.id,
        { expectedRevision: detail.value.item.revision, note: removeNote.value.trim() },
      )
      : await removeRaceSeasonReward(
        detail.value.item.id,
        removeTarget.value.item.id,
        { expectedRevision: detail.value.item.revision, note: removeNote.value.trim() },
      );
    afterMutation(result);
    removeDialogOpen.value = false;
    ElMessage.success(removeTarget.value.kind === 'task' ? '任务已移除' : '排名奖励已移除');
  } catch (error) {
    ElMessage.error(errorMessage(error, '移除失败'));
    handleConflict(error);
  } finally {
    removing.value = false;
  }
}

function handleConflict(error: unknown): void {
  if (error instanceof ApiError && error.code === 'race_season_revision_conflict') void load();
}

function requestStatus(target: SeasonAction): void {
  if (detail.value) emit('status', target, detail.value);
}

function changeLeaderboardPage(page: number): void {
  leaderboardPage.value = page;
  void load();
}

function changeLeaderboardPageSize(pageSize: number): void {
  leaderboardPageSize.value = pageSize;
  leaderboardPage.value = 1;
  void load();
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(1040px, 98vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="item" class="detail-heading">
        <span class="season-mark"><ElIcon><Trophy /></ElIcon></span>
        <div><span>RACE SEASON · REVISION {{ item.revision }}</span><h2>{{ item.title }}</h2><p>{{ item.seasonKey }} · {{ item.participants }} 位参与者</p></div>
        <ElTag :type="raceSeasonStatusTone(item.status)" effect="plain">{{ raceSeasonStatusLabel(item.status) }}</ElTag>
      </div>
    </template>

    <div v-loading="loading" class="detail-body">
      <template v-if="detail && item">
        <div class="detail-actions">
          <div>
            <ElButton v-if="editable" :icon="EditPen" @click="emit('edit', item)">编辑配置</ElButton>
            <ElButton :icon="Refresh" @click="load">刷新</ElButton>
          </div>
          <div>
            <ElButton
              v-for="transition in detail.transitions"
              :key="transition"
              :type="transition === 'active' ? 'primary' : transition === 'ended' ? 'danger' : 'warning'"
              :plain="transition !== 'active'"
              @click="requestStatus(transition)"
            >{{ raceSeasonTransitionLabel(transition) }}</ElButton>
            <ElButton v-if="item.status === 'active' || item.status === 'paused'" type="danger" plain :icon="Medal" @click="requestStatus('finalize')">结算赛季</ElButton>
          </div>
        </div>

        <section class="detail-metrics">
          <div><span>参与用户</span><strong>{{ item.participants.toLocaleString() }}</strong><small>{{ item.settlementRecords }} 条轮次记录</small></div>
          <div><span>有效任务</span><strong>{{ item.activeTaskCount }}</strong><small>共 {{ item.taskCount }} 个</small></div>
          <div><span>排名奖励</span><strong>{{ item.activeRewardCount }}</strong><small>共 {{ item.rewardCount }} 项</small></div>
          <div><span>成长值预算</span><strong>{{ detail.budget.maximumPoints.toLocaleString() }}</strong><small>已发 {{ detail.budget.awardedPoints.toLocaleString() }}</small></div>
          <div><span>樱花币预算</span><strong>{{ detail.budget.maximumCoins.toLocaleString() }}</strong><small>已发 {{ detail.budget.awardedCoins.toLocaleString() }}</small></div>
        </section>

        <ElAlert v-if="structureLocked" title="赛季结构已锁定" description="已有参与数据后不能增加或移除任务、奖励，也不能修改积分与排名奖励条款。" type="warning" :closable="false" show-icon />
        <ElAlert v-for="warning in detail.warnings" :key="warning.code + warning.rewardIds.join('-')" :title="warning.message" type="warning" :closable="false" show-icon />

        <ElTabs v-model="activeTab" class="detail-tabs">
          <ElTabPane name="overview" label="赛季配置">
            <section class="season-overview">
              <dl>
                <div><dt>开始时间</dt><dd>{{ formatDateTime(item.startsAt) }}</dd></div>
                <div><dt>结束时间</dt><dd>{{ formatDateTime(item.endsAt) }}</dd></div>
                <div><dt>每轮参与积分</dt><dd>{{ item.config.participationPoints }}</dd></div>
                <div><dt>获胜额外积分</dt><dd>{{ item.config.winPoints }}</dd></div>
                <div><dt>收益加分上限</dt><dd>{{ item.config.maxProfitBonus }}</dd></div>
                <div><dt>最近修改</dt><dd>{{ formatDateTime(item.updatedAt) }}</dd></div>
                <div class="wide"><dt>赛季说明</dt><dd>{{ item.description || '未填写' }}</dd></div>
              </dl>
            </section>

            <section class="tier-band">
              <header><strong>段位门槛</strong><small>按累计赛季积分自动升级</small></header>
              <div>
                <article v-for="tier in item.config.tiers" :key="tier.key"><span>{{ raceTierLabel(tier.key) }}</span><strong>{{ tier.points.toLocaleString() }}</strong><small>起始积分</small></article>
              </div>
            </section>

            <section class="budget-band">
              <header><div><strong>最大奖励预算</strong><small>按当前有效用户与奖励名次范围计算的保守上限</small></div><ElTag type="info" effect="plain">上线确认项</ElTag></header>
              <div class="budget-grid">
                <article><span>任务成长值</span><strong>{{ detail.budget.maximumTaskPoints.toLocaleString() }}</strong><small>单用户 {{ detail.budget.taskPointsPerUser }}</small></article>
                <article><span>任务樱花币</span><strong>{{ detail.budget.maximumTaskCoins.toLocaleString() }}</strong><small>单用户 {{ detail.budget.taskCoinsPerUser }}</small></article>
                <article><span>排名成长值</span><strong>{{ detail.budget.maximumRankingPoints.toLocaleString() }}</strong><small>{{ detail.rewards.filter((entry) => entry.status === 'active').length }} 项有效奖励</small></article>
                <article><span>排名樱花币</span><strong>{{ detail.budget.maximumRankingCoins.toLocaleString() }}</strong><small>{{ detail.budget.rankingExposure.reduce((sum, entry) => sum + entry.slots, 0) }} 个名额上限</small></article>
              </div>
            </section>
          </ElTabPane>

          <ElTabPane name="tasks" :label="`赛季任务 ${detail.tasks.length}`">
            <div class="tab-toolbar"><div><strong>用户任务</strong><small>按结算数据自动累计，完成后由用户领取。</small></div><ElButton v-if="editable && !structureLocked" type="primary" plain :icon="Plus" @click="openTask(null)">添加任务</ElButton></div>
            <section class="item-list">
              <article v-for="task in detail.tasks" :key="task.id">
                <span class="item-icon"><ElIcon><Tickets /></ElIcon></span>
                <div class="item-main"><strong>{{ task.title }}</strong><small>{{ task.taskKey }} · {{ raceMetricLabel(task.metric) }}达到 {{ task.targetCount.toLocaleString() }}</small><p>{{ task.progressUsers }} 人有进度 · {{ task.completedUsers }} 人完成 · {{ task.claimCount }} 人领取</p></div>
                <ElTag :type="task.status === 'active' ? 'success' : 'info'" effect="plain">{{ task.status === 'active' ? '有效' : '停用' }}</ElTag>
                <div class="reward-value"><strong>+{{ task.rewardPoints }} / +{{ task.rewardCoins }}</strong><small>成长值 / 樱花币</small></div>
                <span v-if="task.identityLocked || task.rewardLocked" class="lock-state"><ElIcon><Lock /></ElIcon>已锁定</span>
                <div v-if="editable" class="item-actions"><ElTooltip content="编辑任务"><ElButton circle :icon="EditPen" aria-label="编辑任务" @click="openTask(task)" /></ElTooltip><ElTooltip v-if="!structureLocked && !task.progressUsers && !task.claimCount" content="移除任务"><ElButton circle type="danger" plain :icon="Delete" aria-label="移除任务" @click="openRemove({ kind: 'task', item: task })" /></ElTooltip></div>
              </article>
              <ElEmpty v-if="!detail.tasks.length" :image-size="64" description="尚未配置赛季任务" />
            </section>
          </ElTabPane>

          <ElTabPane name="rewards" :label="`排名奖励 ${detail.rewards.length}`">
            <div class="tab-toolbar"><div><strong>最终排名奖励</strong><small>赛季结算时按最终榜单幂等发放。</small></div><ElButton v-if="editable && !structureLocked" type="primary" plain :icon="Plus" @click="openReward(null)">添加奖励</ElButton></div>
            <section class="item-list reward-list">
              <article v-for="reward in detail.rewards" :key="reward.id">
                <span class="item-icon reward"><ElIcon><Medal /></ElIcon></span>
                <div class="item-main"><strong>{{ reward.title }}</strong><small>{{ reward.rewardKey }} · {{ raceRewardScopeLabel(reward) }}</small><p>{{ reward.claimCount }} 人已发放 · 成长值 {{ reward.awardedPoints }} · 樱花币 {{ reward.awardedCoins }}</p></div>
                <ElTag :type="reward.status === 'active' ? 'success' : 'info'" effect="plain">{{ reward.status === 'active' ? '有效' : '停用' }}</ElTag>
                <div class="reward-value"><strong>+{{ reward.rewardPoints }} / +{{ reward.rewardCoins }}</strong><small>成长值 / 樱花币</small></div>
                <span v-if="structureLocked || reward.termsLocked" class="lock-state"><ElIcon><Lock /></ElIcon>条款锁定</span>
                <div v-if="editable" class="item-actions"><ElTooltip content="编辑奖励"><ElButton circle :icon="EditPen" aria-label="编辑奖励" @click="openReward(reward)" /></ElTooltip><ElTooltip v-if="!structureLocked && !reward.claimCount" content="移除奖励"><ElButton circle type="danger" plain :icon="Delete" aria-label="移除奖励" @click="openRemove({ kind: 'reward', item: reward })" /></ElTooltip></div>
              </article>
              <ElEmpty v-if="!detail.rewards.length" :image-size="64" description="尚未配置排名奖励" />
            </section>
          </ElTabPane>

          <ElTabPane name="leaderboard" :label="`实时榜单 ${detail.leaderboard.total}`">
            <section class="leaderboard-table">
              <ElTable :data="detail.leaderboard.items" row-key="rank" empty-text="尚无赛季参与数据">
                <ElTableColumn label="名次" width="70" align="center"><template #default="{ row }"><span class="rank" :class="{ top: row.rank <= 3 }">{{ row.rank }}</span></template></ElTableColumn>
                <ElTableColumn label="用户" min-width="220"><template #default="{ row }"><div class="user-cell"><span>{{ row.user.nickname?.slice(0, 1) || 'U' }}</span><div><strong>{{ row.user.nickname || `用户 ${row.user.id}` }}</strong><small>{{ row.user.email }}</small></div></div></template></ElTableColumn>
                <ElTableColumn label="段位" min-width="90"><template #default="{ row }">{{ raceTierLabel(row.tier) }}</template></ElTableColumn>
                <ElTableColumn prop="points" label="积分" min-width="90" align="right" />
                <ElTableColumn prop="rounds" label="轮次" min-width="80" align="right" />
                <ElTableColumn prop="wins" label="获胜" min-width="80" align="right" />
                <ElTableColumn label="收益" min-width="100" align="right"><template #default="{ row }"><span :class="{ profit: row.profit > 0, loss: row.profit < 0 }">{{ row.profit > 0 ? '+' : '' }}{{ row.profit }}</span></template></ElTableColumn>
                <ElTableColumn label="更新" min-width="120"><template #default="{ row }">{{ formatDateTime(row.updatedAt) }}</template></ElTableColumn>
              </ElTable>
              <div v-if="detail.leaderboard.total" class="table-pagination"><span>共 {{ detail.leaderboard.total }} 位参与者</span><ElPagination background layout="sizes, prev, pager, next" :current-page="leaderboardPage" :page-size="leaderboardPageSize" :page-sizes="[10, 20, 50]" :total="detail.leaderboard.total" @current-change="changeLeaderboardPage" @size-change="changeLeaderboardPageSize" /></div>
            </section>
          </ElTabPane>

          <ElTabPane name="audit" :label="`审计 ${detail.events.length}`">
            <section class="audit-list">
              <article v-for="event in detail.events" :key="event.id"><span><ElIcon><DocumentChecked /></ElIcon></span><div><strong>{{ raceSeasonActionLabel(event.action) }}</strong><p>{{ event.note }}</p><small>{{ event.admin.nickname || event.admin.email }} · {{ formatDateTime(event.createdAt) }}</small></div></article>
              <ElEmpty v-if="!detail.events.length" :image-size="64" description="暂无赛季审计记录" />
            </section>
          </ElTabPane>
        </ElTabs>

        <RaceSeasonTaskDialog v-if="detail" v-model="taskDialogOpen" :detail="detail" :task="editingTask" @saved="afterMutation" @reload="load" />
        <RaceSeasonRewardDialog v-if="detail" v-model="rewardDialogOpen" :detail="detail" :reward="editingReward" @saved="afterMutation" @reload="load" />

        <ElDialog v-model="removeDialogOpen" width="min(520px, 92vw)" append-to-body :close-on-click-modal="false">
          <template #header><div class="remove-heading"><ElIcon><WarningFilled /></ElIcon><div><strong>移除{{ removeTarget?.kind === 'task' ? '赛季任务' : '排名奖励' }}</strong><small>仅没有参与数据和历史记录的配置可以移除。</small></div></div></template>
          <ElFormItem label="移除原因" required class="remove-note"><ElInput v-model="removeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明为什么移除该配置" /></ElFormItem>
          <template #footer><ElButton @click="removeDialogOpen = false">取消</ElButton><ElButton type="danger" :loading="removing" @click="remove">确认移除</ElButton></template>
        </ElDialog>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.detail-heading { width: 100%; display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; gap: 11px; }
.season-mark { width: 44px; height: 44px; display: grid; place-items: center; border-radius: 8px; color: #8a671e; background: #fff1d1; font-size: 18px; }
.detail-heading > div { min-width: 0; }
.detail-heading > div > span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .08em; }
.detail-heading h2 { overflow: hidden; margin: 3px 0 2px; color: var(--ink-900); font-size: 18px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.detail-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }
.detail-body { display: grid; gap: 13px; min-height: 300px; }
.detail-actions { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.detail-actions > div { display: flex; gap: 8px; flex-wrap: wrap; }
.detail-metrics { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.detail-metrics > div { min-width: 0; display: grid; gap: 4px; padding: 13px; border-right: 1px solid var(--line); }
.detail-metrics > div:last-child { border-right: 0; }
.detail-metrics span, .detail-metrics small { color: var(--ink-500); font-size: 9px; }
.detail-metrics strong { overflow: hidden; color: var(--ink-900); font-size: 17px; letter-spacing: 0; text-overflow: ellipsis; white-space: nowrap; }
.season-overview, .tier-band, .budget-band, .item-list, .leaderboard-table, .audit-list { border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.season-overview dl { margin: 0; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); }
.season-overview dl div { min-width: 0; padding: 13px; border-right: 1px solid var(--line); border-bottom: 1px solid var(--line); }
.season-overview dl div:nth-child(3n) { border-right: 0; }
.season-overview dl .wide { grid-column: 1 / -1; border-right: 0; }
.season-overview dt { color: var(--ink-500); font-size: 9px; }
.season-overview dd { margin: 4px 0 0; color: var(--ink-900); font-size: 11px; line-height: 1.5; }
.tier-band, .budget-band { margin-top: 13px; }
.tier-band > header, .budget-band > header { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 12px 14px; border-bottom: 1px solid var(--line); }
.tier-band header strong, .budget-band header strong { display: block; color: var(--ink-900); font-size: 11px; }
.tier-band header small, .budget-band header small { display: block; margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.tier-band > div { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); }
.tier-band article, .budget-grid article { min-width: 0; display: grid; gap: 4px; padding: 12px; border-right: 1px solid var(--line); }
.tier-band article:last-child, .budget-grid article:last-child { border-right: 0; }
.tier-band article span, .tier-band article small, .budget-grid span, .budget-grid small { color: var(--ink-500); font-size: 9px; }
.tier-band article strong, .budget-grid strong { color: var(--ink-900); font-size: 15px; letter-spacing: 0; }
.budget-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); }
.tab-toolbar { min-height: 48px; display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 10px; }
.tab-toolbar > div { display: grid; gap: 2px; }
.tab-toolbar strong { color: var(--ink-900); font-size: 12px; }
.tab-toolbar small { color: var(--ink-500); font-size: 9px; }
.item-list article { display: grid; grid-template-columns: auto minmax(210px, 1fr) auto minmax(120px, .4fr) auto auto; align-items: center; gap: 10px; padding: 12px 14px; border-bottom: 1px solid var(--line); }
.item-list article:last-child { border-bottom: 0; }
.item-icon { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 7px; color: var(--sakura-700); background: var(--sakura-50); }
.item-icon.reward { color: #89661c; background: #fff1d1; }
.item-main { min-width: 0; }
.item-main strong, .item-main small, .item-main p { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.item-main strong { color: var(--ink-900); font-size: 11px; }
.item-main small { margin-top: 2px; color: var(--ink-500); font-size: 9px; }
.item-main p { margin: 3px 0 0; color: var(--ink-600); font-size: 9px; }
.reward-value { display: grid; gap: 2px; text-align: right; }
.reward-value strong { color: var(--ink-900); font-size: 11px; }
.reward-value small { color: var(--ink-500); font-size: 8px; }
.lock-state { display: inline-flex; align-items: center; gap: 4px; color: #7d6631; font-size: 9px; }
.item-actions { display: flex; gap: 5px; }
.rank { width: 28px; height: 28px; display: grid; place-items: center; margin: auto; border-radius: 7px; color: var(--ink-600); background: var(--surface-muted); font-size: 10px; font-weight: 800; }
.rank.top { color: #8a5c16; background: #fff0cf; }
.user-cell { min-width: 0; display: flex; align-items: center; gap: 8px; }
.user-cell > span { width: 29px; height: 29px; display: grid; place-items: center; border-radius: 50%; color: var(--sakura-700); background: var(--sakura-50); font-size: 10px; font-weight: 800; }
.user-cell > div { min-width: 0; }
.user-cell strong, .user-cell small { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.user-cell strong { color: var(--ink-900); font-size: 10px; }
.user-cell small { color: var(--ink-500); font-size: 9px; }
.profit { color: #2d7c5e; }.loss { color: #b44b61; }
.table-pagination { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 12px 14px; border-top: 1px solid var(--line); }
.table-pagination > span { color: var(--ink-500); font-size: 9px; }
.audit-list { padding: 0 14px; }
.audit-list article { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 10px; padding: 11px 0; border-bottom: 1px solid var(--line); }
.audit-list article > span { width: 30px; height: 30px; display: grid; place-items: center; border-radius: 7px; color: #58697d; background: #edf1f5; }
.audit-list strong { color: var(--ink-900); font-size: 11px; }
.audit-list p { margin: 3px 0; color: var(--ink-700); font-size: 10px; }
.audit-list small { color: var(--ink-500); font-size: 9px; }
.remove-heading { display: flex; align-items: flex-start; gap: 9px; color: #a34358; }
.remove-heading > .el-icon { margin-top: 2px; }
.remove-heading div { display: grid; gap: 3px; }
.remove-heading strong { font-size: 14px; }
.remove-heading small { color: var(--ink-500); font-size: 10px; }
.remove-note { display: grid; }
.remove-note :deep(.el-form-item__label) { justify-content: flex-start; }
@media (max-width: 760px) {
  .detail-actions { align-items: flex-start; flex-direction: column; }
  .detail-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .detail-metrics > div { border-bottom: 1px solid var(--line); }
  .season-overview dl { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .season-overview dl div:nth-child(3n) { border-right: 1px solid var(--line); }
  .season-overview dl div:nth-child(2n) { border-right: 0; }
  .tier-band > div, .budget-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .item-list article { grid-template-columns: auto minmax(0, 1fr) auto; }
  .item-list article > .el-tag, .reward-value, .lock-state { grid-column: 2; text-align: left; }
  .item-actions { grid-column: 3; grid-row: 1 / span 4; }
}
@media (max-width: 480px) {
  .season-overview dl, .tier-band > div, .budget-grid { grid-template-columns: 1fr; }
  .season-overview dl div { border-right: 0 !important; }
}
</style>
