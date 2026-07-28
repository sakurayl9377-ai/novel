<script setup lang="ts">
import {
  Coin,
  Connection,
  DocumentChecked,
  Present,
  Refresh,
  Search,
  Tickets,
  User,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useRouter } from 'vue-router';

import MetricCard from '@/components/MetricCard.vue';
import KdjxGmDeliveryDialog from '@/components/kdjx-gm/KdjxGmDeliveryDialog.vue';
import {
  getKdjxGmCatalog,
  getKdjxGmDeliveries,
  getKdjxGmPayments,
  getKdjxGmPlayer,
  getKdjxGmWorkbench,
  retryKdjxGmPayment,
  revokeKdjxGmSessions,
} from '@/services/kdjx-gm';
import type {
  KdjxGmActionLog,
  KdjxGmCatalogItem,
  KdjxGmCreateDeliveryResponse,
  KdjxGmDelivery,
  KdjxGmDeliveryStatus,
  KdjxGmDeliveryType,
  KdjxGmPayment,
  KdjxGmPlayer,
  KdjxGmPlayerDetailResponse,
  KdjxGmSummary,
  KdjxGmWorkbenchResponse,
  KdjxPaymentStatus,
  KdjxUserStatus,
} from '@/types/kdjx-gm';
import { formatDateTime } from '@/utils/format';
import {
  formatYuan,
  kdjxGmActionLabel,
  kdjxGmActionResultLabel,
  kdjxGmActionResultTone,
  kdjxGmDeliveryStatusLabel,
  kdjxGmDeliveryStatusTone,
  kdjxPaymentStatusLabel,
  kdjxPaymentStatusTone,
  kdjxSessionStatusLabel,
  kdjxSessionStatusTone,
  kdjxUserStatusLabel,
  kdjxUserStatusTone,
} from '@/utils/kdjx-gm';

type WorkbenchTab = 'players' | 'deliveries' | 'payments' | 'audit';

const router = useRouter();
const loadingPlayers = ref(false);
const loadingPayments = ref(false);
const loadingCatalog = ref(false);
const loadingDeliveries = ref(false);
const initialized = ref(false);
const activeTab = ref<WorkbenchTab>('players');
const busyKey = ref('');
const compactMedia = window.matchMedia('(max-width: 720px)');
const compactLayout = ref(compactMedia.matches);

const emptySummary = (): KdjxGmSummary => ({
  linkedPlayers: 0,
  activeGameSessions: 0,
  paymentOrders: 0,
  deliveryFailed: 0,
  fulfilled: 0,
  totalCoinSpend: 0,
});

const workbench = ref<KdjxGmWorkbenchResponse>({
  generatedAt: '',
  page: 1,
  pageSize: 20,
  total: 0,
  summary: emptySummary(),
  players: [],
  recentActions: [],
});
const playerQuery = reactive({
  q: '',
  status: '' as '' | KdjxUserStatus,
  page: 1,
  pageSize: 20,
});
const paymentQuery = reactive({
  q: '',
  status: '' as '' | KdjxPaymentStatus,
  userId: '' as '' | number,
  page: 1,
  pageSize: 20,
});
const payments = ref<KdjxGmPayment[]>([]);
const paymentTotal = ref(0);
const paymentsLoaded = ref(false);
const catalog = ref<KdjxGmCatalogItem[]>([]);
const catalogLoaded = ref(false);
const deliveries = ref<KdjxGmDelivery[]>([]);
const deliveryTotal = ref(0);
const deliveriesLoaded = ref(false);
const deliveryDialogOpen = ref(false);
const deliveryPlayer = ref<KdjxGmPlayer | null>(null);
const deliveryQuery = reactive({
  q: '',
  status: '' as '' | KdjxGmDeliveryStatus,
  userId: '' as '' | number,
  page: 1,
  pageSize: 20,
});

const detailOpen = ref(false);
const detailLoading = ref(false);
const detail = ref<KdjxGmPlayerDetailResponse | null>(null);
let detailRequestVersion = 0;

const failedRate = computed(() => workbench.value.summary.paymentOrders
  ? Math.round(
    (workbench.value.summary.deliveryFailed /
      workbench.value.summary.paymentOrders) * 100,
  )
  : 0);

onMounted(async () => {
  compactMedia.addEventListener('change', updateCompactLayout);
  await Promise.all([loadPlayers(), loadCatalog()]);
});

onBeforeUnmount(() => {
  compactMedia.removeEventListener('change', updateCompactLayout);
  detailRequestVersion += 1;
});

watch(detailOpen, (open) => {
  if (open) return;
  detailRequestVersion += 1;
  detailLoading.value = false;
  detail.value = null;
});

watch(deliveryDialogOpen, (open) => {
  if (!open) deliveryPlayer.value = null;
});

function updateCompactLayout(event: MediaQueryListEvent): void {
  compactLayout.value = event.matches;
}

async function loadPlayers(silent = false): Promise<void> {
  if (!silent) loadingPlayers.value = true;
  try {
    workbench.value = await getKdjxGmWorkbench(playerQuery);
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 玩家工作台加载失败'));
  } finally {
    if (!silent) loadingPlayers.value = false;
    initialized.value = true;
  }
}

async function loadPayments(silent = false): Promise<void> {
  if (!silent) loadingPayments.value = true;
  try {
    const response = await getKdjxGmPayments(paymentQuery);
    payments.value = response.payments;
    paymentTotal.value = response.total;
    paymentsLoaded.value = true;
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 支付订单加载失败'));
  } finally {
    if (!silent) loadingPayments.value = false;
  }
}

async function loadCatalog(): Promise<void> {
  if (loadingCatalog.value) return;
  loadingCatalog.value = true;
  try {
    const response = await getKdjxGmCatalog();
    catalog.value = response.items;
    catalogLoaded.value = true;
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 物品目录加载失败'));
  } finally {
    loadingCatalog.value = false;
  }
}

async function loadDeliveries(silent = false): Promise<void> {
  if (!silent) loadingDeliveries.value = true;
  try {
    const response = await getKdjxGmDeliveries(deliveryQuery);
    deliveries.value = response.deliveries;
    deliveryTotal.value = response.total;
    deliveriesLoaded.value = true;
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 物品发放记录加载失败'));
  } finally {
    if (!silent) loadingDeliveries.value = false;
  }
}

function changeTab(name: string | number): void {
  const next = String(name) as WorkbenchTab;
  activeTab.value = next;
  if (next === 'payments' && !paymentsLoaded.value) void loadPayments();
  if (next === 'deliveries' && !deliveriesLoaded.value) void loadDeliveries();
}

function searchPlayers(): void {
  playerQuery.page = 1;
  void loadPlayers();
}

function resetPlayers(): void {
  Object.assign(playerQuery, { q: '', status: '', page: 1 });
  void loadPlayers();
}

function changePlayerPage(page: number): void {
  playerQuery.page = page;
  void loadPlayers();
}

function searchPayments(): void {
  paymentQuery.page = 1;
  void loadPayments();
}

function resetPayments(): void {
  Object.assign(paymentQuery, { q: '', status: '', userId: '', page: 1 });
  void loadPayments();
}

function changePaymentPage(page: number): void {
  paymentQuery.page = page;
  void loadPayments();
}

function searchDeliveries(): void {
  deliveryQuery.page = 1;
  void loadDeliveries();
}

function resetDeliveries(): void {
  Object.assign(deliveryQuery, {
    q: '',
    status: '',
    userId: '',
    page: 1,
  });
  void loadDeliveries();
}

function changeDeliveryPage(page: number): void {
  deliveryQuery.page = page;
  void loadDeliveries();
}

function openDelivery(player: KdjxGmPlayer): void {
  if (!player.canDeliverItems) {
    ElMessage.warning('玩家的游戏身份关联不完整，请先让玩家重新登录一次游戏');
    return;
  }
  deliveryPlayer.value = player;
  deliveryDialogOpen.value = true;
  if (!catalogLoaded.value) void loadCatalog();
}

async function deliverySent(response: KdjxGmCreateDeliveryResponse): Promise<void> {
  await Promise.all([
    loadPlayers(true),
    loadDeliveries(true),
    detail.value?.player.userId === response.delivery.userId
      ? refreshDetail()
      : Promise.resolve(),
  ]);
}

async function openPlayer(player: KdjxGmPlayer): Promise<void> {
  const requestVersion = ++detailRequestVersion;
  detailOpen.value = true;
  detailLoading.value = true;
  detail.value = null;
  try {
    const response = await getKdjxGmPlayer(player.userId);
    if (requestVersion !== detailRequestVersion || !detailOpen.value) return;
    detail.value = response;
  } catch (error) {
    if (requestVersion !== detailRequestVersion) return;
    ElMessage.error(errorMessage(error, '玩家详情加载失败'));
    detailOpen.value = false;
  } finally {
    if (requestVersion === detailRequestVersion) {
      detailLoading.value = false;
    }
  }
}

async function refreshDetail(): Promise<void> {
  if (!detail.value) return;
  const userId = detail.value.player.userId;
  const requestVersion = ++detailRequestVersion;
  detailLoading.value = true;
  try {
    const response = await getKdjxGmPlayer(userId);
    if (requestVersion !== detailRequestVersion || !detailOpen.value) return;
    detail.value = response;
  } catch (error) {
    if (requestVersion !== detailRequestVersion) return;
    ElMessage.error(errorMessage(error, '玩家详情刷新失败'));
  } finally {
    if (requestVersion === detailRequestVersion) {
      detailLoading.value = false;
    }
  }
}

async function confirmRevoke(player: KdjxGmPlayer): Promise<void> {
  if (busyKey.value || player.activeGameSessions <= 0) return;
  const reason = await requestReason(
    `将使“${player.nickname || player.email}”的全部 KDJX 登录凭据失效，不影响其 Sakura/App 登录。`,
    '吊销 KDJX 游戏会话',
    '例如：玩家反馈账号异常，要求重新登录游戏',
  );
  if (!reason) return;
  try {
    await ElMessageBox.confirm(
      `当前显示 ${player.activeGameSessions} 个有效游戏会话。确认全部吊销？操作原因：${reason}`,
      '最后确认',
      {
        type: 'warning',
        confirmButtonText: '确认吊销',
        cancelButtonText: '取消',
      },
    );
  } catch (error) {
    if (!isDialogCancel(error)) {
      ElMessage.error(errorMessage(error, '吊销确认失败'));
    }
    return;
  }

  busyKey.value = `revoke:${player.userId}`;
  try {
    const response = await revokeKdjxGmSessions(player.userId, {
      reason,
      expectedActiveSessions: player.activeGameSessions,
    });
    ElMessage.success(`已吊销 ${response.revokedSessions} 个 KDJX 游戏凭据`);
    await Promise.all([
      loadPlayers(true),
      detail.value?.player.userId === player.userId
        ? refreshDetail()
        : Promise.resolve(),
    ]);
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 游戏会话吊销失败'));
    await loadPlayers(true);
  } finally {
    busyKey.value = '';
  }
}

async function confirmRetry(payment: KdjxGmPayment): Promise<void> {
  if (busyKey.value || !payment.canRetry) return;
  const reason = await requestReason(
    `仅重新投递已存在的订单“${payment.gameOrderId}”，不会再次扣除樱花币。`,
    '补发 KDJX 支付订单',
    '例如：核对游戏服务恢复后重新投递',
  );
  if (!reason) return;
  try {
    await ElMessageBox.confirm(
      `订单状态为“${kdjxPaymentStatusLabel(payment.status)}”，玩家 ${payment.email}，金额 ${formatYuan(payment.moneyCents)}。确认补发？`,
      '最后确认',
      {
        type: 'warning',
        confirmButtonText: '确认补发',
        cancelButtonText: '取消',
      },
    );
  } catch (error) {
    if (!isDialogCancel(error)) {
      ElMessage.error(errorMessage(error, '补发确认失败'));
    }
    return;
  }

  busyKey.value = `retry:${payment.gameOrderId}`;
  try {
    const response = await retryKdjxGmPayment(payment, reason);
    if (response.ok) {
      ElMessage.success('订单已成功补发并确认到账');
    } else {
      ElMessage.error('补发仍未到账，已记录最新错误，请检查游戏服务后再试');
    }
    await Promise.all([
      loadPayments(true),
      loadPlayers(true),
      detail.value?.player.userId === payment.userId
        ? refreshDetail()
        : Promise.resolve(),
    ]);
  } catch (error) {
    ElMessage.error(errorMessage(error, 'KDJX 支付订单补发失败'));
    await Promise.all([loadPayments(true), loadPlayers(true)]);
  } finally {
    busyKey.value = '';
  }
}

async function requestReason(
  message: string,
  title: string,
  placeholder: string,
): Promise<string> {
  try {
    const result = await ElMessageBox.prompt(message, title, {
      inputPlaceholder: placeholder,
      inputType: 'textarea',
      inputValidator: (value: string) => {
        const reason = String(value || '').trim();
        if (reason.length < 4) return '请填写至少 4 个字的具体原因';
        if (reason.length > 160) return '操作原因不能超过 160 个字';
        return true;
      },
      confirmButtonText: '下一步',
      cancelButtonText: '取消',
      type: 'warning',
    });
    return result.value.trim();
  } catch (error) {
    if (!isDialogCancel(error)) {
      ElMessage.error(errorMessage(error, '操作原因输入失败'));
    }
    return '';
  }
}

function openUserWorkbench(userId: number): void {
  void router.push({ name: 'users', query: { userId: String(userId) } });
}

function openGameControls(): void {
  void router.push({ name: 'games' });
}

function asPlayer(row: unknown): KdjxGmPlayer {
  return row as KdjxGmPlayer;
}

function asPayment(row: unknown): KdjxGmPayment {
  return row as KdjxGmPayment;
}

function asDelivery(row: unknown): KdjxGmDelivery {
  return row as KdjxGmDelivery;
}

function asAction(row: unknown): KdjxGmActionLog {
  return row as KdjxGmActionLog;
}

function deliveryTypeLabel(type: KdjxGmDeliveryType): string {
  return type === 'mail' ? '邮件附件' : '直接到账';
}

function formatCoins(value: number): string {
  return new Intl.NumberFormat('zh-CN').format(Number(value || 0));
}

function shortId(value: string, length = 18): string {
  const text = String(value || '');
  return text.length <= length ? text : `${text.slice(0, length)}…`;
}

function isDialogCancel(error: unknown): boolean {
  return error === 'cancel' || error === 'close';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="page-stack kdjx-gm-page">
    <section class="gm-hero">
      <div>
        <span class="eyebrow">KDJX GAME MASTER</span>
        <h2>KDJX 安全运营工作台</h2>
        <p>查询 Sakura 用户与游戏角色的关联、安全发放白名单物品、处理独立游戏会话和失败支付订单。账号封禁、余额调整及服务启停仍由现有管理模块完成。</p>
      </div>
      <div class="hero-actions">
        <ElButton @click="openGameControls">游戏服务</ElButton>
        <ElButton :icon="Refresh" :loading="loadingPlayers" @click="loadPlayers()">刷新</ElButton>
      </div>
    </section>

    <ElAlert
      title="本工作台不会读取或展示游戏密码、会话令牌、令牌哈希和后端密钥"
      type="info"
      :closable="false"
      show-icon
    />

    <ElSkeleton v-if="!initialized && loadingPlayers" :rows="8" animated />
    <template v-else>
      <section class="metric-grid gm-metrics">
        <MetricCard label="关联玩家" :value="workbench.summary.linkedPlayers" hint="已建立 Sakura 与 KDJX 关联" :icon="User" />
        <MetricCard label="有效游戏会话" :value="workbench.summary.activeGameSessions" hint="仅 KDJX 独立登录凭据" :icon="Connection" tone="success" />
        <MetricCard label="支付订单" :value="workbench.summary.paymentOrders" hint="全部 KDJX 樱花币订单" :icon="Tickets" />
        <MetricCard label="投递失败" :value="workbench.summary.deliveryFailed" :hint="`失败率 ${failedRate}%`" :icon="WarningFilled" :tone="workbench.summary.deliveryFailed ? 'danger' : 'success'" />
        <MetricCard label="累计消耗樱花币" :value="formatCoins(workbench.summary.totalCoinSpend)" hint="已创建订单的累计扣款" :icon="Coin" />
      </section>

      <section class="gm-workbench">
        <ElTabs v-model="activeTab" class="gm-tabs" @tab-change="changeTab">
          <ElTabPane name="players" label="关联玩家">
            <div class="filter-bar">
              <ElInput
                v-model="playerQuery.q"
                clearable
                placeholder="用户 ID、邮箱、昵称、openId、角色或服务器"
                :prefix-icon="Search"
                @keyup.enter="searchPlayers"
              />
              <ElSelect v-model="playerQuery.status" clearable placeholder="账号状态">
                <ElOption label="正常" value="active" />
                <ElOption label="已封禁" value="banned" />
              </ElSelect>
              <ElButton type="primary" :loading="loadingPlayers" @click="searchPlayers">查询</ElButton>
              <ElButton @click="resetPlayers">重置</ElButton>
            </div>

            <ElTable
              v-if="!compactLayout"
              v-loading="loadingPlayers"
              :data="workbench.players"
              row-key="userId"
              class="gm-table"
            >
              <ElTableColumn label="Sakura 用户" min-width="230">
                <template #default="{ row }">
                  <button class="identity-link" type="button" @click="openPlayer(asPlayer(row))">
                    <strong>{{ asPlayer(row).nickname || '未设置昵称' }}</strong>
                    <span>{{ asPlayer(row).email }}</span>
                    <small>ID {{ asPlayer(row).userId }} · {{ formatCoins(asPlayer(row).sakuraCoins) }} 樱花币</small>
                  </button>
                </template>
              </ElTableColumn>
              <ElTableColumn label="账号" width="105">
                <template #default="{ row }">
                  <ElTag :type="kdjxUserStatusTone(asPlayer(row).userStatus)" effect="plain">
                    {{ kdjxUserStatusLabel(asPlayer(row).userStatus) }}
                  </ElTag>
                </template>
              </ElTableColumn>
              <ElTableColumn label="KDJX 关联" min-width="250">
                <template #default="{ row }">
                  <div class="stacked-cell mono-cell">
                    <strong>{{ asPlayer(row).gameOpenId }}</strong>
                    <span>账号 {{ asPlayer(row).gameAccountId || '尚未记录' }}</span>
                    <small>角色 {{ asPlayer(row).lastRoleId || '—' }} · {{ asPlayer(row).lastServerKey || '—' }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="会话" width="105" align="center">
                <template #default="{ row }">
                  <strong :class="{ 'danger-text': asPlayer(row).activeGameSessions > 2 }">
                    {{ asPlayer(row).activeGameSessions }}
                  </strong>
                </template>
              </ElTableColumn>
              <ElTableColumn label="最近支付" min-width="170">
                <template #default="{ row }">
                  <div class="stacked-cell">
                    <ElTag :type="kdjxPaymentStatusTone(asPlayer(row).lastPaymentStatus)" size="small" effect="plain">
                      {{ kdjxPaymentStatusLabel(asPlayer(row).lastPaymentStatus) }}
                    </ElTag>
                    <small>{{ formatDateTime(asPlayer(row).lastPaymentAt) }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="操作" width="290" align="right" fixed="right">
                <template #default="{ row }">
                  <div class="table-actions">
                    <ElButton size="small" @click="openPlayer(asPlayer(row))">详情</ElButton>
                    <ElButton
                      size="small"
                      type="primary"
                      plain
                      :icon="Present"
                      :disabled="!asPlayer(row).canDeliverItems"
                      @click="openDelivery(asPlayer(row))"
                    >
                      发物品
                    </ElButton>
                    <ElButton
                      size="small"
                      type="warning"
                      plain
                      :disabled="asPlayer(row).activeGameSessions <= 0 || Boolean(busyKey)"
                      :loading="busyKey === `revoke:${asPlayer(row).userId}`"
                      @click="confirmRevoke(asPlayer(row))"
                    >
                      吊销会话
                    </ElButton>
                  </div>
                </template>
              </ElTableColumn>
            </ElTable>

            <div v-else v-loading="loadingPlayers" class="mobile-player-list">
              <article v-for="player in workbench.players" :key="player.userId" class="mobile-player">
                <button class="identity-link" type="button" @click="openPlayer(player)">
                  <strong>{{ player.nickname || '未设置昵称' }}</strong>
                  <span>{{ player.email }}</span>
                  <small>ID {{ player.userId }} · {{ formatCoins(player.sakuraCoins) }} 樱花币</small>
                </button>
                <div class="mobile-player-status">
                  <ElTag :type="kdjxUserStatusTone(player.userStatus)" size="small" effect="plain">
                    {{ kdjxUserStatusLabel(player.userStatus) }}
                  </ElTag>
                  <span>{{ player.activeGameSessions }} 个有效会话</span>
                </div>
                <dl>
                  <div><dt>角色</dt><dd>{{ player.lastRoleId || '尚未同步' }}</dd></div>
                  <div><dt>服务器</dt><dd>{{ player.lastServerKey || '尚未同步' }}</dd></div>
                </dl>
                <div class="mobile-player-actions">
                  <ElButton size="small" @click="openPlayer(player)">详情</ElButton>
                  <ElButton
                    size="small"
                    type="primary"
                    plain
                    :icon="Present"
                    :disabled="!player.canDeliverItems"
                    @click="openDelivery(player)"
                  >
                    发物品
                  </ElButton>
                  <ElButton
                    size="small"
                    type="warning"
                    plain
                    :disabled="player.activeGameSessions <= 0 || Boolean(busyKey)"
                    :loading="busyKey === `revoke:${player.userId}`"
                    @click="confirmRevoke(player)"
                  >
                    吊销会话
                  </ElButton>
                </div>
              </article>
              <ElEmpty
                v-if="!loadingPlayers && !workbench.players.length"
                :image-size="56"
                description="没有符合条件的关联玩家"
              />
            </div>

            <div class="pagination-row">
              <span>共 {{ workbench.total }} 位关联玩家</span>
              <ElPagination
                background
                layout="prev, pager, next"
                :current-page="playerQuery.page"
                :page-size="playerQuery.pageSize"
                :total="workbench.total"
                @current-change="changePlayerPage"
              />
            </div>
          </ElTabPane>

          <ElTabPane name="deliveries" label="物品发放">
            <div class="filter-bar delivery-filter">
              <ElInput
                v-model="deliveryQuery.q"
                clearable
                placeholder="玩家、物品、角色、服务器或请求号"
                :prefix-icon="Search"
                @keyup.enter="searchDeliveries"
              />
              <ElSelect v-model="deliveryQuery.status" clearable placeholder="发放状态">
                <ElOption label="发放中" value="pending" />
                <ElOption label="已发送" value="succeeded" />
                <ElOption label="发送失败" value="failed" />
                <ElOption label="结果待核对" value="unknown" />
              </ElSelect>
              <ElInput v-model="deliveryQuery.userId" clearable placeholder="用户 ID" />
              <ElButton type="primary" :loading="loadingDeliveries" @click="searchDeliveries">查询</ElButton>
              <ElButton @click="resetDeliveries">重置</ElButton>
            </div>

            <ElTable
              v-loading="loadingDeliveries"
              :data="deliveries"
              row-key="id"
              class="gm-table delivery-table"
            >
              <ElTableColumn label="时间 / 请求" min-width="190">
                <template #default="{ row }">
                  <div class="stacked-cell mono-cell">
                    <strong>{{ formatDateTime(asDelivery(row).createdAt) }}</strong>
                    <small>{{ shortId(asDelivery(row).requestId, 24) }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="玩家" min-width="210">
                <template #default="{ row }">
                  <button class="identity-link compact" type="button" @click="openUserWorkbench(asDelivery(row).userId)">
                    <strong>{{ asDelivery(row).nickname || asDelivery(row).email }}</strong>
                    <span>{{ asDelivery(row).email }}</span>
                    <small>ID {{ asDelivery(row).userId }} · {{ asDelivery(row).roleId }}</small>
                  </button>
                </template>
              </ElTableColumn>
              <ElTableColumn label="物品" min-width="205">
                <template #default="{ row }">
                  <div class="stacked-cell">
                    <strong>{{ asDelivery(row).itemName }} × {{ asDelivery(row).quantity }}</strong>
                    <span>{{ asDelivery(row).itemQuality }} · {{ asDelivery(row).itemType }}</span>
                    <small>ID {{ asDelivery(row).itemId }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="目标" min-width="170">
                <template #default="{ row }">
                  <div class="stacked-cell mono-cell">
                    <strong>{{ asDelivery(row).roleId }}</strong>
                    <small>{{ asDelivery(row).serverKey }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="方式" width="105">
                <template #default="{ row }">
                  <ElTag size="small" effect="plain">
                    {{ deliveryTypeLabel(asDelivery(row).deliveryType) }}
                  </ElTag>
                </template>
              </ElTableColumn>
              <ElTableColumn label="状态" width="120">
                <template #default="{ row }">
                  <ElTooltip :content="asDelivery(row).errorCode || asDelivery(row).remoteReference || '发放记录已完成'">
                    <ElTag :type="kdjxGmDeliveryStatusTone(asDelivery(row).status)" effect="plain">
                      {{ kdjxGmDeliveryStatusLabel(asDelivery(row).status) }}
                    </ElTag>
                  </ElTooltip>
                </template>
              </ElTableColumn>
              <ElTableColumn label="原因 / 管理员" min-width="230">
                <template #default="{ row }">
                  <div class="stacked-cell">
                    <span class="reason-copy">{{ asDelivery(row).reason }}</span>
                    <small>{{ asDelivery(row).adminEmail || `管理员 ID ${asDelivery(row).adminUserId ?? '—'}` }}</small>
                  </div>
                </template>
              </ElTableColumn>
            </ElTable>

            <div class="pagination-row">
              <span>共 {{ deliveryTotal }} 条发放记录</span>
              <ElPagination
                background
                layout="prev, pager, next"
                :current-page="deliveryQuery.page"
                :page-size="deliveryQuery.pageSize"
                :total="deliveryTotal"
                @current-change="changeDeliveryPage"
              />
            </div>
          </ElTabPane>

          <ElTabPane name="payments" label="支付订单">
            <div class="filter-bar payment-filter">
              <ElInput
                v-model="paymentQuery.q"
                clearable
                placeholder="订单号、玩家、角色、商品"
                :prefix-icon="Search"
                @keyup.enter="searchPayments"
              />
              <ElSelect v-model="paymentQuery.status" clearable placeholder="订单状态">
                <ElOption label="已扣款，待投递" value="paid" />
                <ElOption label="投递中" value="fulfilling" />
                <ElOption label="投递失败" value="delivery_failed" />
                <ElOption label="已到账" value="fulfilled" />
              </ElSelect>
              <ElInput v-model="paymentQuery.userId" clearable placeholder="用户 ID" />
              <ElButton type="primary" :loading="loadingPayments" @click="searchPayments">查询</ElButton>
              <ElButton @click="resetPayments">重置</ElButton>
            </div>

            <ElTable v-loading="loadingPayments" :data="payments" row-key="id" class="gm-table payment-table">
              <ElTableColumn label="订单" min-width="235">
                <template #default="{ row }">
                  <div class="stacked-cell mono-cell">
                    <strong>{{ asPayment(row).gameOrderId }}</strong>
                    <span>{{ asPayment(row).channelOrderId }}</span>
                    <small>{{ formatDateTime(asPayment(row).createdAt) }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="玩家" min-width="210">
                <template #default="{ row }">
                  <button class="identity-link compact" type="button" @click="openUserWorkbench(asPayment(row).userId)">
                    <strong>{{ asPayment(row).nickname || asPayment(row).email }}</strong>
                    <span>{{ asPayment(row).email }}</span>
                    <small>ID {{ asPayment(row).userId }} · 角色 {{ shortId(asPayment(row).roleId) }}</small>
                  </button>
                </template>
              </ElTableColumn>
              <ElTableColumn label="商品与扣款" min-width="175">
                <template #default="{ row }">
                  <div class="stacked-cell">
                    <strong>{{ asPayment(row).productName }}</strong>
                    <span>{{ formatYuan(asPayment(row).moneyCents) }} · {{ asPayment(row).coinCost }} 樱花币</span>
                    <small>投递 {{ asPayment(row).attempts }} 次</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="状态" width="150">
                <template #default="{ row }">
                  <ElTag :type="kdjxPaymentStatusTone(asPayment(row).status)" effect="plain">
                    {{ kdjxPaymentStatusLabel(asPayment(row).status) }}
                  </ElTag>
                </template>
              </ElTableColumn>
              <ElTableColumn label="最近错误" min-width="220">
                <template #default="{ row }">
                  <span v-if="asPayment(row).lastError" class="error-copy">{{ asPayment(row).lastError }}</span>
                  <span v-else class="muted-copy">—</span>
                </template>
              </ElTableColumn>
              <ElTableColumn label="操作" width="120" align="right" fixed="right">
                <template #default="{ row }">
                  <ElButton
                    size="small"
                    type="warning"
                    plain
                    :disabled="!asPayment(row).canRetry || Boolean(busyKey)"
                    :loading="busyKey === `retry:${asPayment(row).gameOrderId}`"
                    @click="confirmRetry(asPayment(row))"
                  >
                    失败补发
                  </ElButton>
                </template>
              </ElTableColumn>
            </ElTable>

            <div class="pagination-row">
              <span>共 {{ paymentTotal }} 笔订单</span>
              <ElPagination
                background
                layout="prev, pager, next"
                :current-page="paymentQuery.page"
                :page-size="paymentQuery.pageSize"
                :total="paymentTotal"
                @current-change="changePaymentPage"
              />
            </div>
          </ElTabPane>

          <ElTabPane name="audit" label="操作审计">
            <div class="audit-note">
              <ElIcon><DocumentChecked /></ElIcon>
              <div>
                <strong>最近 20 条 KDJX GM 写操作</strong>
                <span>写操作会先登记再执行；成功、失败或中断待确认均保留记录，不保存请求密钥或响应正文。</span>
              </div>
            </div>
            <ElTable :data="workbench.recentActions" row-key="id" class="gm-table">
              <ElTableColumn label="时间" width="125">
                <template #default="{ row }">{{ formatDateTime(asAction(row).createdAt) }}</template>
              </ElTableColumn>
              <ElTableColumn label="管理员" min-width="190">
                <template #default="{ row }">
                  <div class="stacked-cell">
                    <strong>{{ asAction(row).adminNickname || '已删除管理员' }}</strong>
                    <small>{{ asAction(row).adminEmail || `ID ${asAction(row).adminUserId ?? '—'}` }}</small>
                  </div>
                </template>
              </ElTableColumn>
              <ElTableColumn label="操作" width="150">
                <template #default="{ row }">{{ kdjxGmActionLabel(asAction(row).action) }}</template>
              </ElTableColumn>
              <ElTableColumn label="目标" min-width="180">
                <template #default="{ row }"><code>{{ asAction(row).targetId }}</code></template>
              </ElTableColumn>
              <ElTableColumn label="原因" min-width="250" prop="reason" />
              <ElTableColumn label="结果" width="110">
                <template #default="{ row }">
                  <ElTooltip
                    :content="asAction(row).errorCode || (
                      asAction(row).result === 'pending'
                        ? '服务在完成审计前中断，请人工核对目标状态'
                        : '操作完成'
                    )"
                  >
                    <ElTag :type="kdjxGmActionResultTone(asAction(row).result)" effect="plain">
                      {{ kdjxGmActionResultLabel(asAction(row).result) }}
                    </ElTag>
                  </ElTooltip>
                </template>
              </ElTableColumn>
            </ElTable>
          </ElTabPane>
        </ElTabs>
      </section>
    </template>

    <ElDrawer v-model="detailOpen" size="min(760px, 94vw)" destroy-on-close>
      <template #header>
        <div class="drawer-heading">
          <div>
            <span class="eyebrow">PLAYER DETAIL</span>
            <h3>{{ detail?.player.nickname || detail?.player.email || 'KDJX 玩家详情' }}</h3>
          </div>
          <ElButton :icon="Refresh" :loading="detailLoading" @click="refreshDetail">刷新</ElButton>
        </div>
      </template>

      <ElSkeleton v-if="detailLoading && !detail" :rows="9" animated />
      <div v-else-if="detail" class="drawer-body">
        <div class="drawer-actions">
          <ElButton @click="openUserWorkbench(detail.player.userId)">打开用户管理</ElButton>
          <ElButton
            type="primary"
            plain
            :icon="Present"
            :disabled="!detail.player.canDeliverItems"
            @click="openDelivery(detail.player)"
          >
            发放物品
          </ElButton>
          <ElButton
            type="warning"
            plain
            :disabled="detail.player.activeGameSessions <= 0 || Boolean(busyKey)"
            :loading="busyKey === `revoke:${detail.player.userId}`"
            @click="confirmRevoke(detail.player)"
          >
            吊销全部 KDJX 会话
          </ElButton>
        </div>

        <ElDescriptions :column="compactLayout ? 1 : 2" border class="player-descriptions">
          <ElDescriptionsItem label="Sakura 用户">{{ detail.player.email }}（ID {{ detail.player.userId }}）</ElDescriptionsItem>
          <ElDescriptionsItem label="账号状态">
            <ElTag :type="kdjxUserStatusTone(detail.player.userStatus)" size="small" effect="plain">
              {{ kdjxUserStatusLabel(detail.player.userStatus) }}
            </ElTag>
          </ElDescriptionsItem>
          <ElDescriptionsItem label="樱花币">{{ formatCoins(detail.player.sakuraCoins) }}</ElDescriptionsItem>
          <ElDescriptionsItem label="有效游戏会话">{{ detail.player.activeGameSessions }}</ElDescriptionsItem>
          <ElDescriptionsItem label="game openId"><code>{{ detail.player.gameOpenId }}</code></ElDescriptionsItem>
          <ElDescriptionsItem label="accountId"><code>{{ detail.player.gameAccountId || '—' }}</code></ElDescriptionsItem>
          <ElDescriptionsItem label="roleId"><code>{{ detail.player.lastRoleId || '—' }}</code></ElDescriptionsItem>
          <ElDescriptionsItem label="serverKey"><code>{{ detail.player.lastServerKey || '—' }}</code></ElDescriptionsItem>
          <ElDescriptionsItem label="关联时间">{{ formatDateTime(detail.player.linkedAt) }}</ElDescriptionsItem>
          <ElDescriptionsItem label="最后同步">{{ formatDateTime(detail.player.linkedUpdatedAt) }}</ElDescriptionsItem>
        </ElDescriptions>

        <section class="detail-section">
          <header><h4>物品发放</h4><span>最近 {{ detail.deliveries.length }} 条</span></header>
          <ElTable :data="detail.deliveries" row-key="id" size="small">
            <ElTableColumn label="物品" min-width="170">
              <template #default="{ row }">
                <div class="stacked-cell">
                  <strong>{{ asDelivery(row).itemName }} × {{ asDelivery(row).quantity }}</strong>
                  <small>{{ asDelivery(row).itemQuality }} · {{ asDelivery(row).itemType }} · ID {{ asDelivery(row).itemId }}</small>
                </div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="方式" width="100">
              <template #default="{ row }">{{ deliveryTypeLabel(asDelivery(row).deliveryType) }}</template>
            </ElTableColumn>
            <ElTableColumn label="状态" width="115">
              <template #default="{ row }">
                <ElTag :type="kdjxGmDeliveryStatusTone(asDelivery(row).status)" size="small" effect="plain">
                  {{ kdjxGmDeliveryStatusLabel(asDelivery(row).status) }}
                </ElTag>
              </template>
            </ElTableColumn>
            <ElTableColumn label="时间" width="120">
              <template #default="{ row }">{{ formatDateTime(asDelivery(row).createdAt) }}</template>
            </ElTableColumn>
          </ElTable>
        </section>

        <section class="detail-section">
          <header><h4>游戏会话</h4><span>最近 {{ detail.sessions.length }} 条</span></header>
          <ElTable :data="detail.sessions" row-key="id" size="small">
            <ElTableColumn label="会话记录" min-width="190">
              <template #default="{ row }"><code>{{ shortId(String(row.id), 24) }}</code></template>
            </ElTableColumn>
            <ElTableColumn label="状态" width="90">
              <template #default="{ row }">
                <ElTag :type="kdjxSessionStatusTone(row.status)" size="small" effect="plain">
                  {{ kdjxSessionStatusLabel(row.status) }}
                </ElTag>
              </template>
            </ElTableColumn>
            <ElTableColumn label="最后使用" width="120">
              <template #default="{ row }">{{ formatDateTime(row.lastUsedAt) }}</template>
            </ElTableColumn>
            <ElTableColumn label="到期时间" width="120">
              <template #default="{ row }">{{ formatDateTime(row.expiresAt) }}</template>
            </ElTableColumn>
          </ElTable>
        </section>

        <section class="detail-section">
          <header><h4>最近支付</h4><span>{{ detail.payments.length }} 笔</span></header>
          <ElTable :data="detail.payments" row-key="id" size="small">
            <ElTableColumn label="订单" min-width="190">
              <template #default="{ row }"><code>{{ row.gameOrderId }}</code></template>
            </ElTableColumn>
            <ElTableColumn label="商品" min-width="140" prop="productName" />
            <ElTableColumn label="扣款" width="105">
              <template #default="{ row }">{{ row.coinCost }} 樱花币</template>
            </ElTableColumn>
            <ElTableColumn label="状态" width="125">
              <template #default="{ row }">
                <ElTag :type="kdjxPaymentStatusTone(row.status)" size="small" effect="plain">
                  {{ kdjxPaymentStatusLabel(row.status) }}
                </ElTag>
              </template>
            </ElTableColumn>
          </ElTable>
        </section>
      </div>
    </ElDrawer>

    <KdjxGmDeliveryDialog
      v-model="deliveryDialogOpen"
      :player="deliveryPlayer"
      :catalog="catalog"
      :catalog-loading="loadingCatalog"
      @sent="deliverySent"
    />
  </div>
</template>

<style scoped>
.kdjx-gm-page { gap: 16px; }
.gm-hero { min-height: 136px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 24px; border: 1px solid var(--line); border-left: 4px solid var(--sakura-500); border-radius: 8px; background: radial-gradient(circle at 95% 10%, var(--sakura-50), transparent 36%), white; box-shadow: var(--shadow-sm); }
.gm-hero h2 { margin: 7px 0 6px; color: var(--ink-900); font-size: 25px; }
.gm-hero p { max-width: 850px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.7; }
.hero-actions, .table-actions, .drawer-actions { display: flex; align-items: center; gap: 8px; }
.gm-metrics { grid-template-columns: repeat(5, minmax(145px, 1fr)); gap: 10px; }
.gm-metrics :deep(.metric-card) { min-height: 112px; padding: 14px; }
.gm-workbench { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }
.gm-tabs :deep(.el-tabs__header) { margin: 0; padding: 0 18px; border-bottom: 1px solid var(--line); }
.gm-tabs :deep(.el-tabs__nav-wrap::after) { display: none; }
.gm-tabs :deep(.el-tab-pane) { padding: 16px 18px 18px; }
.filter-bar { display: grid; grid-template-columns: minmax(260px, 1fr) 160px auto auto; gap: 9px; margin-bottom: 14px; }
.payment-filter { grid-template-columns: minmax(240px, 1fr) 170px 130px auto auto; }
.delivery-filter { grid-template-columns: minmax(250px, 1fr) 145px 115px auto auto; }
.gm-table { width: 100%; }
.identity-link { width: 100%; display: grid; gap: 3px; border: 0; padding: 0; text-align: left; color: inherit; background: transparent; cursor: pointer; }
.identity-link:hover strong { color: var(--sakura-600); }
.identity-link strong, .stacked-cell strong { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.identity-link span, .stacked-cell span { overflow: hidden; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
.identity-link small, .stacked-cell small { overflow: hidden; color: var(--ink-300); font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }
.identity-link.compact strong { font-size: 11px; }
.stacked-cell { min-width: 0; display: grid; justify-items: start; gap: 4px; }
.mono-cell strong, .mono-cell span, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.danger-text, .error-copy { color: #b4233e; }
.error-copy { font-size: 10px; line-height: 1.5; }
.muted-copy { color: var(--ink-300); }
.pagination-row { min-height: 58px; display: flex; align-items: flex-end; justify-content: space-between; gap: 16px; padding-top: 16px; }
.pagination-row > span { color: var(--ink-500); font-size: 11px; }
.audit-note { display: flex; align-items: center; gap: 12px; margin-bottom: 14px; padding: 13px 15px; border-radius: 7px; color: #315b75; background: #f0f7fb; }
.audit-note > .el-icon { flex: 0 0 auto; font-size: 24px; }
.audit-note > div { display: grid; gap: 3px; }
.audit-note strong { font-size: 12px; }
.audit-note span { font-size: 10px; }
.reason-copy { overflow: hidden; max-width: 100%; color: var(--ink-600); font-size: 10px; line-height: 1.5; text-overflow: ellipsis; white-space: nowrap; }
.mobile-player-list { display: grid; gap: 10px; }
.mobile-player { display: grid; gap: 11px; padding: 13px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.mobile-player-status { display: flex; align-items: center; justify-content: space-between; gap: 10px; color: var(--ink-500); font-size: 10px; }
.mobile-player dl { display: grid; gap: 7px; margin: 0; padding: 10px 0; border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); }
.mobile-player dl > div { min-width: 0; display: grid; grid-template-columns: 52px minmax(0, 1fr); gap: 8px; }
.mobile-player dt { color: var(--ink-400); font-size: 10px; }
.mobile-player dd { overflow-wrap: anywhere; margin: 0; color: var(--ink-700); font: 10px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
.mobile-player-actions { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 7px; }
.mobile-player-actions > .el-button { min-width: 0; margin: 0; padding-inline: 8px; }
.drawer-heading { width: 100%; display: flex; align-items: center; justify-content: space-between; gap: 18px; }
.drawer-heading h3 { margin: 5px 0 0; color: var(--ink-900); font-size: 19px; }
.drawer-body { min-width: 0; display: grid; gap: 18px; }
.drawer-actions { justify-content: flex-end; }
.player-descriptions { min-width: 0; }
.player-descriptions :deep(.el-descriptions__label) { width: 118px; }
.player-descriptions :deep(.el-descriptions__content) { min-width: 0; overflow-wrap: anywhere; }
.detail-section { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; }
.detail-section > header { min-height: 52px; display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 0 14px; border-bottom: 1px solid var(--line); }
.detail-section h4 { margin: 0; color: var(--ink-900); font-size: 13px; }
.detail-section header span { color: var(--ink-500); font-size: 10px; }
@media (max-width: 1180px) {
  .gm-metrics { grid-template-columns: repeat(3, minmax(145px, 1fr)); }
  .gm-workbench { overflow-x: auto; }
  .gm-tabs { min-width: 980px; }
}
@media (max-width: 720px) {
  .gm-workbench { overflow: hidden; }
  .gm-tabs { min-width: 0; }
  .gm-tabs :deep(.el-tabs__header) { padding-inline: 12px; }
  .gm-tabs :deep(.el-tab-pane) { padding: 13px 12px 15px; }
  .filter-bar,
  .payment-filter,
  .delivery-filter { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .filter-bar > :first-child { grid-column: 1 / -1; }
  .gm-hero { align-items: flex-start; flex-direction: column; }
  .hero-actions { width: 100%; }
  .hero-actions > .el-button { flex: 1; }
  .gm-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .drawer-actions { align-items: stretch; flex-wrap: wrap; }
  .drawer-actions > .el-button { min-width: 150px; flex: 1; }
  .player-descriptions code { overflow-wrap: anywhere; word-break: break-all; }
  .pagination-row { align-items: center; flex-direction: column; }
  .pagination-row > span { align-self: flex-start; }
}
</style>
