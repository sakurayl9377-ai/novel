<script setup lang="ts">
import {
  Coin,
  DataLine,
  Document,
  Filter,
  Lock,
  Plus,
  Refresh,
  Search,
  User,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';
import { useRouter } from 'vue-router';

import FinanceEventDrawer from '@/components/finance/FinanceEventDrawer.vue';
import MetricCard from '@/components/MetricCard.vue';
import UserEconomyDialog from '@/components/users/UserEconomyDialog.vue';
import { getFinanceWorkbench } from '@/services/finance';
import { adjustUserEconomy, listUsers } from '@/services/users';
import type {
  FinanceCurrency,
  FinanceDailyFlow,
  FinanceDirection,
  FinanceEvent,
  FinancePeriod,
  FinanceWorkbenchResponse,
} from '@/types/finance';
import type { AdminUser, UserEconomyPayload } from '@/types/user';
import { formatDateTime } from '@/utils/format';
import {
  financeActionLabel,
  financeEventDirection,
  financeEventDirectionLabel,
  financeRelatedTypeLabel,
  signedAsset,
} from '@/utils/finance';

const router = useRouter();
const loading = ref(false);
const initialized = ref(false);
const data = ref<FinanceWorkbenchResponse>(emptyWorkbench());
const query = reactive({
  q: '',
  period: '30d' as FinancePeriod,
  currency: '' as FinanceCurrency,
  direction: '' as FinanceDirection,
  action: '',
  page: 1,
  pageSize: 20,
});

const detailOpen = ref(false);
const selectedEvent = ref<FinanceEvent | null>(null);
const targetDialogOpen = ref(false);
const targetSearching = ref(false);
const targetUserId = ref<number | null>(null);
const targetOptions = ref<AdminUser[]>([]);
const selectedTarget = ref<AdminUser | null>(null);
const economyOpen = ref(false);
const economySaving = ref(false);

const filterCount = computed(() => [
  query.q,
  query.currency,
  query.direction,
  query.action,
  query.period === '30d' ? '' : query.period,
].filter(Boolean).length);
const selectedTargetOption = computed(() => targetOptions.value.find((item) => item.id === targetUserId.value) || null);
const recentDaily = computed(() => data.value.daily.slice(-14));
const chartMaximum = computed(() => Math.max(
  1,
  ...recentDaily.value.map((item) => item.pointsCredit + item.pointsDebit + item.coinsCredit + item.coinsDebit),
));
const integrityHealthy = computed(() => data.value.balances.negativeBalances === 0);

onMounted(() => void loadFinance());

async function loadFinance(): Promise<void> {
  loading.value = true;
  try {
    data.value = await getFinanceWorkbench(query);
  } catch (error) {
    ElMessage.error(errorMessage(error, '资金流水加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function searchFinance(): void {
  query.page = 1;
  void loadFinance();
}

function resetFilters(): void {
  Object.assign(query, {
    q: '',
    period: '30d',
    currency: '',
    direction: '',
    action: '',
    page: 1,
  });
  void loadFinance();
}

function changePage(page: number): void {
  query.page = page;
  void loadFinance();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadFinance();
}

function openEvent(event: FinanceEvent): void {
  selectedEvent.value = event;
  detailOpen.value = true;
}

function viewUser(userId: number): void {
  detailOpen.value = false;
  void router.push({ name: 'users', query: { userId: String(userId) } });
}

async function openAdjustmentTarget(): Promise<void> {
  targetUserId.value = null;
  selectedTarget.value = null;
  targetDialogOpen.value = true;
  await searchTargets('');
}

async function searchTargets(keyword: string): Promise<void> {
  targetSearching.value = true;
  try {
    const response = await listUsers({ q: keyword.trim(), sort: 'recent', page: 1, pageSize: 10 });
    targetOptions.value = response.items;
  } catch (error) {
    ElMessage.error(errorMessage(error, '用户搜索失败'));
  } finally {
    targetSearching.value = false;
  }
}

function continueAdjustment(): void {
  const target = selectedTargetOption.value;
  if (!target) {
    ElMessage.warning('请先搜索并选择需要记账的用户');
    return;
  }
  selectedTarget.value = target;
  targetDialogOpen.value = false;
  economyOpen.value = true;
}

async function saveEconomy(payload: UserEconomyPayload): Promise<void> {
  const user = selectedTarget.value;
  if (!user || economySaving.value) return;
  economySaving.value = true;
  try {
    const result = await adjustUserEconomy(user.id, payload);
    selectedTarget.value = result.item;
    economyOpen.value = false;
    const asset = result.currency === 'coins' ? '樱花币' : '成长值';
    ElMessage.success(`${asset}已从 ${result.previousBalance.toLocaleString()} 调整为 ${result.nextBalance.toLocaleString()}，账变已追加到流水`);
    await loadFinance();
  } catch (error) {
    ElMessage.error(errorMessage(error, '人工账变失败'));
  } finally {
    economySaving.value = false;
  }
}

function chartHeight(item: FinanceDailyFlow): string {
  const amount = item.pointsCredit + item.pointsDebit + item.coinsCredit + item.coinsDebit;
  return `${Math.max(amount ? 8 : 2, Math.round((amount / chartMaximum.value) * 100))}%`;
}

function chartLabel(day: string): string {
  const parts = day.split('-');
  return parts.length === 3 ? `${parts[1]}/${parts[2]}` : day;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): FinanceWorkbenchResponse {
  return {
    page: 1,
    pageSize: 20,
    total: 0,
    filters: { period: '30d', currency: '', direction: '', action: '' },
    summary: {
      affectedUsers: 0,
      pointsDelta: 0,
      pointsIssued: 0,
      pointsSpent: 0,
      coinsDelta: 0,
      coinsIssued: 0,
      coinsSpent: 0,
    },
    balances: { users: 0, totalPoints: 0, totalCoins: 0, coinHolders: 0, negativeBalances: 0 },
    actions: [],
    daily: [],
    items: [],
  };
}
</script>

<template>
  <div class="page-stack finance-page">
    <section class="finance-hero">
      <div class="hero-copy">
        <span class="eyebrow">IMMUTABLE ASSET LEDGER</span>
        <h2>每一笔成长值与樱花币，都能追到用户和业务来源</h2>
        <p>统一核对签到、互动、商品兑换、活动奖励和人工调整；历史流水只追加不修改，纠错通过反向账变完成。</p>
      </div>
      <div class="hero-actions">
        <div class="integrity-state" :class="{ danger: !integrityHealthy }">
          <span class="integrity-icon"><ElIcon><Lock v-if="integrityHealthy" /><WarningFilled v-else /></ElIcon></span>
          <div><strong>{{ integrityHealthy ? '余额完整性正常' : '发现异常负余额' }}</strong><span>{{ integrityHealthy ? '当前没有用户资产低于 0' : `${data.balances.negativeBalances} 个账号需要立即复核` }}</span></div>
        </div>
        <ElButton type="primary" :icon="Plus" @click="openAdjustmentTarget">人工账变</ElButton>
      </div>
    </section>

    <section class="metric-grid finance-metric-grid">
      <MetricCard label="筛选流水" :value="data.total.toLocaleString()" :icon="Document" hint="符合当前条件的账变事件" />
      <MetricCard label="涉及用户" :value="data.summary.affectedUsers.toLocaleString()" :icon="User" hint="当前筛选内去重用户数" />
      <MetricCard label="成长值净变化" :value="signedAsset(data.summary.pointsDelta)" :icon="DataLine" :tone="data.summary.pointsDelta < 0 ? 'warning' : 'success'" hint="发放减去消耗" />
      <MetricCard label="樱花币净变化" :value="signedAsset(data.summary.coinsDelta)" :icon="Coin" :tone="data.summary.coinsDelta < 0 ? 'warning' : 'success'" hint="发放减去消耗" />
      <MetricCard label="成长值发放" :value="data.summary.pointsIssued.toLocaleString()" :icon="DataLine" hint="当前筛选内累计发放" />
      <MetricCard label="樱花币消耗" :value="data.summary.coinsSpent.toLocaleString()" :icon="Coin" hint="当前筛选内累计消耗" />
    </section>

    <section class="flow-overview">
      <div class="asset-pools">
        <header><span>当前资产池</span><small>实时余额汇总，不是筛选期末快照</small></header>
        <div class="pool-grid">
          <div><span>成长值总量</span><strong>{{ data.balances.totalPoints.toLocaleString() }}</strong><small>{{ data.balances.users.toLocaleString() }} 个注册账号</small></div>
          <div><span>樱花币总量</span><strong>{{ data.balances.totalCoins.toLocaleString() }}</strong><small>{{ data.balances.coinHolders.toLocaleString() }} 个持币账号</small></div>
          <div><span>成长值发放 / 消耗</span><strong>{{ data.summary.pointsIssued.toLocaleString() }} / {{ data.summary.pointsSpent.toLocaleString() }}</strong><small>当前筛选区间</small></div>
          <div><span>樱花币发放 / 消耗</span><strong>{{ data.summary.coinsIssued.toLocaleString() }} / {{ data.summary.coinsSpent.toLocaleString() }}</strong><small>当前筛选区间</small></div>
        </div>
      </div>
      <div class="flow-chart">
        <header><span>最近流水强度</span><small>最多显示当前筛选内最近 14 天</small></header>
        <div v-if="recentDaily.length" class="chart-body" aria-label="最近十四天账变强度">
          <div v-for="item in recentDaily" :key="item.day" class="chart-column" :title="`${item.day} · ${item.events} 笔`">
            <span class="chart-value">{{ item.events }}</span>
            <span class="chart-track"><i :style="{ height: chartHeight(item) }" /></span>
            <small>{{ chartLabel(item.day) }}</small>
          </div>
        </div>
        <div v-else class="chart-empty">当前筛选区间暂无流水趋势</div>
      </div>
    </section>

    <section class="finance-workbench">
      <header class="workbench-toolbar">
        <div class="toolbar-copy">
          <h3>账变明细</h3>
          <p>点击详情核对来源；列表中的余额变化是本笔增减值。</p>
        </div>
        <div class="filter-row">
          <ElInput
            v-model="query.q"
            clearable
            class="search-input"
            placeholder="搜索 UID、用户、说明或关联 ID"
            :prefix-icon="Search"
            @keyup.enter="searchFinance"
            @clear="searchFinance"
          />
          <ElSelect v-model="query.period" aria-label="时间范围" class="period-select" @change="searchFinance">
            <ElOption label="今天" value="today" /><ElOption label="最近 7 天" value="7d" /><ElOption label="最近 30 天" value="30d" /><ElOption label="最近 90 天" value="90d" /><ElOption label="最近一年" value="365d" /><ElOption label="全部时间" value="all" />
          </ElSelect>
          <ElSelect v-model="query.currency" aria-label="资产类型" class="filter-select" placeholder="资产类型" @change="searchFinance">
            <ElOption label="全部资产" value="" /><ElOption label="成长值" value="points" /><ElOption label="樱花币" value="coins" /><ElOption label="同时变化" value="mixed" />
          </ElSelect>
          <ElSelect v-model="query.direction" aria-label="账变方向" class="filter-select" placeholder="账变方向" @change="searchFinance">
            <ElOption label="全部方向" value="" /><ElOption label="发放" value="credit" /><ElOption label="扣除" value="debit" />
          </ElSelect>
          <ElSelect v-model="query.action" filterable aria-label="业务来源" class="action-select" placeholder="业务来源" @change="searchFinance">
            <ElOption label="全部来源" value="" />
            <ElOption v-for="item in data.actions" :key="item.action" :label="`${financeActionLabel(item.action)} (${item.count})`" :value="item.action" />
          </ElSelect>
          <ElButton type="primary" :icon="Search" @click="searchFinance">查询</ElButton>
          <ElButton :icon="Refresh" :loading="loading" @click="loadFinance">刷新</ElButton>
          <ElButton v-if="filterCount" text :icon="Filter" @click="resetFilters">清除 {{ filterCount }} 项筛选</ElButton>
        </div>
      </header>

      <div v-loading="loading" class="finance-list">
        <div class="list-head finance-grid" aria-hidden="true">
          <span>用户</span><span>业务来源</span><span>成长值</span><span>樱花币</span><span>发生时间</span><span>操作</span>
        </div>
        <article v-for="event in data.items" :key="event.id" class="event-row finance-grid" @dblclick="openEvent(event)">
          <div class="user-cell">
            <ElAvatar :src="event.user.avatarUrl" :size="38">{{ event.user.nickname?.slice(0, 1) || event.user.id }}</ElAvatar>
            <div><strong>{{ event.user.nickname || `用户 #${event.user.id}` }}</strong><span>{{ event.user.email }}</span><small>UID {{ event.user.id }} · 流水 #{{ event.id }}</small></div>
          </div>
          <div class="source-cell">
            <span><ElTag size="small" :type="financeEventDirection(event) === 'debit' ? 'danger' : financeEventDirection(event) === 'credit' ? 'success' : 'warning'" effect="plain">{{ financeEventDirectionLabel(event) }}</ElTag><strong>{{ financeActionLabel(event.action) }}</strong></span>
            <small>{{ financeRelatedTypeLabel(event.relatedType) }}<template v-if="event.relatedId"> · {{ event.relatedId }}</template></small>
            <em>{{ event.description || '未填写账变说明' }}</em>
          </div>
          <div class="delta-cell" :class="{ credit: event.pointsDelta > 0, debit: event.pointsDelta < 0 }"><strong>{{ signedAsset(event.pointsDelta) }}</strong><span>成长值</span></div>
          <div class="delta-cell" :class="{ credit: event.coinsDelta > 0, debit: event.coinsDelta < 0 }"><strong>{{ signedAsset(event.coinsDelta) }}</strong><span>樱花币</span></div>
          <div class="time-cell"><strong>{{ formatDateTime(event.createdAt) }}</strong><span>{{ event.operator ? `管理员 ${event.operator.nickname}` : '系统或用户行为' }}</span></div>
          <div class="row-actions"><ElButton type="primary" plain size="small" :icon="View" @click.stop="openEvent(event)">详情</ElButton></div>
        </article>

        <div v-if="initialized && !loading && data.items.length === 0" class="friendly-empty list-empty">
          <ElIcon><Coin /></ElIcon><strong>没有符合条件的账变</strong><span>调整时间范围、业务来源或关键词后再试</span>
          <ElButton v-if="filterCount" size="small" @click="resetFilters">清除全部筛选</ElButton>
        </div>
      </div>

      <footer v-if="data.total > 0" class="pagination-row">
        <ElPagination
          background
          :current-page="query.page"
          :page-size="query.pageSize"
          :page-sizes="[10, 20, 50]"
          :pager-count="5"
          layout="total, sizes, prev, pager, next"
          :total="data.total"
          @current-change="changePage"
          @size-change="changePageSize"
        />
      </footer>
    </section>

    <FinanceEventDrawer v-model="detailOpen" :event="selectedEvent" @view-user="viewUser" />

    <ElDialog v-model="targetDialogOpen" title="选择账变用户" width="min(560px, 94vw)" destroy-on-close>
      <div class="target-intro"><span><ElIcon><User /></ElIcon></span><div><strong>先确认账号，再填写账变</strong><p>可按 UID、邮箱或昵称搜索；选中后会展示当前资产，避免调整到同名账号。</p></div></div>
      <ElForm label-position="top">
        <ElFormItem label="目标用户" required>
          <ElSelect
            v-model="targetUserId"
            filterable
            remote
            clearable
            reserve-keyword
            :remote-method="searchTargets"
            :loading="targetSearching"
            class="full-width"
            placeholder="输入 UID、邮箱或昵称搜索"
          >
            <ElOption v-for="user in targetOptions" :key="user.id" :label="`${user.nickname} · ${user.email}`" :value="user.id">
              <div class="target-option"><span><b>{{ user.nickname || `用户 #${user.id}` }}</b><small>{{ user.email }} · UID {{ user.id }}</small></span><em>币 {{ user.growth.sakuraCoins.toLocaleString() }} · 成长值 {{ user.growth.points.toLocaleString() }}</em></div>
            </ElOption>
          </ElSelect>
        </ElFormItem>
      </ElForm>
      <div v-if="selectedTargetOption" class="target-preview">
        <ElAvatar :src="selectedTargetOption.avatarUrl" :size="42">{{ selectedTargetOption.nickname?.slice(0, 1) }}</ElAvatar>
        <div><strong>{{ selectedTargetOption.nickname }}</strong><span>{{ selectedTargetOption.status === 'banned' ? '账号已封禁' : '账号状态正常' }} · Lv.{{ selectedTargetOption.growth.level }}</span></div>
        <p><span>成长值 <b>{{ selectedTargetOption.growth.points.toLocaleString() }}</b></span><span>樱花币 <b>{{ selectedTargetOption.growth.sakuraCoins.toLocaleString() }}</b></span></p>
      </div>
      <template #footer><ElButton @click="targetDialogOpen = false">取消</ElButton><ElButton type="primary" :disabled="!selectedTargetOption" @click="continueAdjustment">下一步</ElButton></template>
    </ElDialog>
    <UserEconomyDialog v-model="economyOpen" :user="selectedTarget" :saving="economySaving" @submit="saveEconomy" />
  </div>
</template>

<style scoped>
.finance-page { --finance-grid: minmax(250px, 1.25fr) minmax(230px, 1.15fr) 105px 105px minmax(150px, .75fr) 86px; }
.finance-hero { display: flex; min-height: 165px; align-items: center; justify-content: space-between; gap: 28px; padding: 27px 31px; border: 1px solid #eadfe4; border-radius: 21px; background: linear-gradient(135deg, #fff 0%, #fffafb 70%, #fff2f6 100%); box-shadow: 0 12px 35px rgb(83 44 64 / 6%); }.hero-copy h2 { margin: 7px 0 8px; color: #352c31; font-size: 28px; letter-spacing: 0; }.hero-copy p { max-width: 780px; margin: 0; color: #806f76; font-size: 13px; line-height: 1.7; }.hero-actions { display: flex; flex: 0 0 auto; align-items: center; gap: 10px; }.integrity-state { display: flex; align-items: center; gap: 9px; padding: 10px 12px; border: 1px solid #dcebdd; border-radius: 13px; background: #f6fcf7; }.integrity-state.danger { border-color: #f0ccd4; background: #fff5f7; }.integrity-icon { display: grid; width: 34px; height: 34px; place-items: center; border-radius: 10px; color: #39825a; background: #dff4e5; }.danger .integrity-icon { color: #be4b69; background: #ffe1e9; }.integrity-state > div { display: flex; flex-direction: column; gap: 2px; }.integrity-state strong { color: #405048; font-size: 11px; }.integrity-state span { color: #7d8d84; font-size: 9px; }.finance-metric-grid { grid-template-columns: repeat(6, minmax(0, 1fr)); }
.flow-overview { display: grid; grid-template-columns: minmax(430px, 1.05fr) minmax(390px, .95fr); overflow: hidden; border: 1px solid #e9e3e6; border-radius: 17px; background: #fff; box-shadow: 0 8px 26px rgb(58 39 51 / 4%); }.asset-pools { border-right: 1px solid #eee7ea; }.asset-pools header, .flow-chart header { display: flex; align-items: center; justify-content: space-between; gap: 10px; padding: 13px 17px; border-bottom: 1px solid #f0eaed; }.asset-pools header span, .flow-chart header span { color: #514148; font-size: 11px; font-weight: 700; }.asset-pools header small, .flow-chart header small { color: #9b888f; font-size: 9px; }.pool-grid { display: grid; grid-template-columns: 1fr 1fr; }.pool-grid > div { display: flex; min-width: 0; flex-direction: column; gap: 3px; padding: 13px 17px; border-right: 1px solid #f0eaed; border-bottom: 1px solid #f0eaed; }.pool-grid > div:nth-child(2n) { border-right: 0; }.pool-grid > div:nth-last-child(-n + 2) { border-bottom: 0; }.pool-grid span { color: #917d85; font-size: 9px; }.pool-grid strong { overflow: hidden; color: #493940; font-size: 16px; text-overflow: ellipsis; white-space: nowrap; }.pool-grid small { color: #a18f95; font-size: 8px; }.chart-body { display: flex; height: 124px; align-items: flex-end; gap: 5px; padding: 13px 13px 9px; }.chart-column { display: grid; min-width: 0; height: 100%; flex: 1; grid-template-rows: 13px 1fr 13px; gap: 3px; text-align: center; }.chart-value { overflow: hidden; color: #9b858d; font-size: 8px; text-overflow: ellipsis; }.chart-track { display: flex; width: 100%; min-height: 65px; align-items: flex-end; overflow: hidden; border-radius: 4px 4px 1px 1px; background: #faf4f6; }.chart-track i { display: block; width: 100%; border-radius: 4px 4px 1px 1px; background: linear-gradient(180deg, #e986a5, #f4b1c5); transition: height 180ms ease; }.chart-column small { color: #9a858d; font-size: 7px; }.chart-empty { display: grid; height: 124px; place-items: center; color: #9b888f; font-size: 10px; }
.finance-workbench { overflow: hidden; border: 1px solid #e9e3e6; border-radius: 18px; background: #fff; box-shadow: 0 10px 32px rgb(58 39 51 / 5%); }.workbench-toolbar { display: flex; align-items: flex-end; justify-content: space-between; gap: 20px; padding: 18px 20px; border-bottom: 1px solid #eee7ea; }.toolbar-copy { flex: 0 0 auto; }.toolbar-copy h3 { margin: 0; color: #403238; font-size: 16px; }.toolbar-copy p { margin: 5px 0 0; color: #927f87; font-size: 10px; }.filter-row { display: flex; flex: 1; flex-wrap: wrap; justify-content: flex-end; gap: 8px; }.search-input { width: 235px; }.period-select { width: 115px; }.filter-select { width: 110px; }.action-select { width: 160px; }.finance-list { min-height: 260px; }.finance-grid { display: grid; grid-template-columns: var(--finance-grid); align-items: center; gap: 14px; }.list-head { min-height: 39px; padding: 0 20px; color: #9e8c93; background: #faf8f9; font-size: 9px; font-weight: 700; }.event-row { min-height: 87px; padding: 12px 20px; border-top: 1px solid #f0eaed; transition: background 140ms ease, box-shadow 140ms ease; }.list-head + .event-row { border-top: 0; }.event-row:hover { position: relative; background: #fffafb; box-shadow: inset 3px 0 #ef92ae; }.user-cell { display: flex; min-width: 0; align-items: center; gap: 10px; }.user-cell > div { display: flex; min-width: 0; flex-direction: column; gap: 2px; }.user-cell strong, .user-cell span, .user-cell small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.user-cell strong { color: #493a40; font-size: 12px; }.user-cell span { color: #826f76; font-size: 9px; }.user-cell small { color: #a08d94; font-size: 8px; }.source-cell { display: flex; min-width: 0; flex-direction: column; gap: 4px; }.source-cell > span { display: flex; min-width: 0; align-items: center; gap: 6px; }.source-cell strong, .source-cell small, .source-cell em { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.source-cell strong { color: #4c3e44; font-size: 11px; }.source-cell small { color: #927e86; font-size: 9px; }.source-cell em { color: #a08d94; font-size: 8px; font-style: normal; }.delta-cell { display: flex; flex-direction: column; gap: 3px; }.delta-cell strong { color: #806f76; font-size: 13px; }.delta-cell span { color: #a08d94; font-size: 8px; }.delta-cell.credit strong { color: #32865a; }.delta-cell.debit strong { color: #c94e6d; }.time-cell { display: flex; min-width: 0; flex-direction: column; gap: 4px; }.time-cell strong, .time-cell span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.time-cell strong { color: #5b4a51; font-size: 10px; }.time-cell span { color: #9b888f; font-size: 8px; }.row-actions { display: flex; justify-content: flex-end; }.list-empty { min-height: 240px; }.pagination-row { display: flex; justify-content: flex-end; padding: 14px 20px; border-top: 1px solid #eee7ea; }
.target-intro { display: flex; align-items: center; gap: 10px; padding: 12px; margin-bottom: 17px; border-radius: 13px; background: #faf7f8; }.target-intro > span { display: grid; width: 38px; height: 38px; place-items: center; border-radius: 11px; color: #b44e70; background: #ffe7ee; }.target-intro strong { color: #4d3e44; font-size: 12px; }.target-intro p { margin: 3px 0 0; color: #927f86; font-size: 10px; }.full-width { width: 100%; }.target-option { display: flex; min-width: 0; align-items: center; justify-content: space-between; gap: 12px; }.target-option > span { display: flex; min-width: 0; flex-direction: column; }.target-option b, .target-option small, .target-option em { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.target-option b { color: #493b40; font-size: 11px; }.target-option small { color: #96838a; font-size: 8px; }.target-option em { color: #886e78; font-size: 9px; font-style: normal; }.target-preview { display: flex; align-items: center; gap: 10px; padding: 12px; border: 1px solid #eadfe3; border-radius: 13px; background: #fffafb; }.target-preview > div { display: flex; min-width: 0; flex: 1; flex-direction: column; gap: 2px; }.target-preview strong { color: #493a40; }.target-preview span { color: #938087; font-size: 9px; }.target-preview p { display: flex; flex-direction: column; align-items: flex-end; gap: 3px; margin: 0; }.target-preview b { color: #56434b; }
@media (max-width: 1500px) { .finance-metric-grid { grid-template-columns: repeat(3, 1fr); }.workbench-toolbar { align-items: flex-start; flex-direction: column; }.filter-row { justify-content: flex-start; } }
@media (max-width: 1280px) { .finance-page { --finance-grid: minmax(230px, 1.25fr) minmax(210px, 1fr) 95px 95px minmax(135px, .75fr) 80px; }.flow-overview { grid-template-columns: 1fr; }.asset-pools { border-right: 0; border-bottom: 1px solid #eee7ea; } }
@media (max-width: 900px) { .finance-hero { align-items: flex-start; flex-direction: column; }.hero-actions { width: 100%; justify-content: space-between; }.finance-page { --finance-grid: minmax(230px, 1.25fr) minmax(200px, 1fr) 95px 95px 80px; }.list-head > span:nth-child(5), .time-cell { display: none; } }
@media (max-width: 650px) { .finance-hero { padding: 22px 19px; }.hero-copy h2 { font-size: 23px; }.hero-actions, .integrity-state { width: 100%; }.hero-actions { align-items: stretch; flex-direction: column; }.finance-metric-grid { grid-template-columns: 1fr 1fr; }.pool-grid { grid-template-columns: 1fr; }.pool-grid > div { border-right: 0; }.pool-grid > div:nth-last-child(2) { border-bottom: 1px solid #f0eaed; }.asset-pools header, .flow-chart header { align-items: flex-start; flex-direction: column; }.filter-row > :deep(.el-input), .filter-row > :deep(.el-select) { width: calc(50% - 4px); }.filter-row > .search-input, .filter-row > .action-select { width: 100%; }.filter-row :deep(.el-button) { margin-left: 0; }.list-head { display: none; }.event-row { display: flex; flex-wrap: wrap; gap: 11px; padding: 14px; }.user-cell, .source-cell { width: 100%; }.delta-cell { flex: 1; }.row-actions { flex: 0 0 95px; }.row-actions :deep(.el-button) { width: 100%; }.pagination-row { overflow-x: auto; justify-content: flex-start; }.target-preview { flex-wrap: wrap; }.target-preview p { width: 100%; flex-direction: row; justify-content: space-between; align-items: center; } }
</style>
