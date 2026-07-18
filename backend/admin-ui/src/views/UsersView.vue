<script setup lang="ts">
import {
  Coin,
  Connection,
  Filter,
  Lock,
  Monitor,
  Refresh,
  Search,
  User,
  UserFilled,
  View,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute } from 'vue-router';

import MetricCard from '@/components/MetricCard.vue';
import UserBanDialog from '@/components/users/UserBanDialog.vue';
import UserDetailDrawer from '@/components/users/UserDetailDrawer.vue';
import UserEconomyDialog from '@/components/users/UserEconomyDialog.vue';
import UserProfileDialog from '@/components/users/UserProfileDialog.vue';
import UserUnbanDialog from '@/components/users/UserUnbanDialog.vue';
import {
  adjustUserEconomy,
  banUser,
  changeUserRole,
  listUsers,
  revokeUserSessions,
  unbanUser,
  updateUserProfile,
} from '@/services/users';
import { useSessionStore } from '@/stores/session';
import type {
  AdminUser,
  UserBanPayload,
  UserEconomyPayload,
  UserProfilePayload,
  UserRiskFilter,
  UserRole,
  UserSort,
  UserStatus,
  UserVersionOption,
  UserWorkbenchStats,
} from '@/types/user';
import { formatDateTime } from '@/utils/format';
import {
  userActivityCount,
  userBanReasonLabel,
  userRiskLabel,
  userRoleLabel,
  userStatusLabel,
} from '@/utils/users';

const session = useSessionStore();
const route = useRoute();
const loading = ref(false);
const initialized = ref(false);
const items = ref<AdminUser[]>([]);
const total = ref(0);
const statusCounts = ref<Partial<Record<UserStatus, number>>>({});
const roleCounts = ref<Partial<Record<UserRole, number>>>({});
const versionOptions = ref<UserVersionOption[]>([]);
const stats = ref<UserWorkbenchStats>({
  total: 0,
  active: 0,
  banned: 0,
  admins: 0,
  newToday: 0,
  activeToday: 0,
  riskUsers: 0,
  chatViolationUsers: 0,
  reportedUsers: 0,
  noVersionUsers: 0,
  activeSessions: 0,
});

const query = reactive({
  q: '',
  status: '' as '' | UserStatus,
  role: '' as '' | UserRole,
  risk: '' as UserRiskFilter,
  appVersionCode: '' as '' | number,
  sort: 'newest' as UserSort,
  page: 1,
  pageSize: 20,
});

const detailOpen = ref(false);
const selectedUserId = ref<number | null>(null);
const selectedUser = ref<AdminUser | null>(null);
const detailRefreshKey = ref(0);
const profileOpen = ref(false);
const profileSaving = ref(false);
const banOpen = ref(false);
const banSaving = ref(false);
const unbanOpen = ref(false);
const unbanSaving = ref(false);
const economyOpen = ref(false);
const economySaving = ref(false);

const activeRate = computed(() => stats.value.total
  ? Math.round((stats.value.active / stats.value.total) * 100)
  : 0);
const filterCount = computed(() => [query.q, query.status, query.role, query.risk, query.appVersionCode]
  .filter((value) => value !== '').length);
const allStatusCount = computed(() => Number(statusCounts.value.active || 0) + Number(statusCounts.value.banned || 0));

onMounted(async () => {
  await loadUsers();
  const deepLinkedUserId = Number(route.query.userId || 0);
  if (!Number.isSafeInteger(deepLinkedUserId) || deepLinkedUserId <= 0) return;
  selectedUserId.value = deepLinkedUserId;
  selectedUser.value = items.value.find((item) => item.id === deepLinkedUserId) || null;
  detailOpen.value = true;
});

async function loadUsers(): Promise<void> {
  loading.value = true;
  try {
    const data = await listUsers(query);
    items.value = data.items;
    total.value = data.total;
    statusCounts.value = data.statusCounts;
    roleCounts.value = data.roleCounts;
    stats.value = data.stats;
    versionOptions.value = data.versionOptions;
    syncSelectedUser();
  } catch (error) {
    ElMessage.error(errorMessage(error, '用户列表加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function searchUsers(): void {
  query.page = 1;
  void loadUsers();
}

function resetFilters(): void {
  Object.assign(query, {
    q: '',
    status: '',
    role: '',
    risk: '',
    appVersionCode: '',
    sort: 'newest',
    page: 1,
  });
  void loadUsers();
}

function quickStatus(status: '' | UserStatus): void {
  query.status = status;
  query.page = 1;
  void loadUsers();
}

function quickRisk(risk: UserRiskFilter): void {
  query.risk = query.risk === risk ? '' : risk;
  query.page = 1;
  void loadUsers();
}

function changePage(page: number): void {
  query.page = page;
  void loadUsers();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadUsers();
}

function openDetail(user: AdminUser): void {
  selectedUserId.value = user.id;
  selectedUser.value = user;
  detailOpen.value = true;
}

function openProfile(user: AdminUser): void {
  selectedUser.value = user;
  profileOpen.value = true;
}

function openBan(user: AdminUser): void {
  if (isCurrentAdmin(user)) {
    ElMessage.warning('不能封禁当前登录的管理员账号');
    return;
  }
  selectedUser.value = user;
  banOpen.value = true;
}

function openUnban(user: AdminUser): void {
  selectedUser.value = user;
  unbanOpen.value = true;
}

function openEconomy(user: AdminUser): void {
  selectedUser.value = user;
  economyOpen.value = true;
}

async function saveProfile(payload: UserProfilePayload): Promise<void> {
  const user = selectedUser.value;
  if (!user || profileSaving.value) return;
  profileSaving.value = true;
  try {
    const result = await updateUserProfile(user.id, payload);
    selectedUser.value = result.item;
    profileOpen.value = false;
    ElMessage.success('用户资料已保存');
    await refreshAfterAction();
  } catch (error) {
    ElMessage.error(errorMessage(error, '资料保存失败'));
  } finally {
    profileSaving.value = false;
  }
}

async function saveBan(payload: UserBanPayload): Promise<void> {
  const user = selectedUser.value;
  if (!user || banSaving.value) return;
  banSaving.value = true;
  try {
    const result = await banUser(user.id, payload);
    selectedUser.value = result.item;
    banOpen.value = false;
    ElMessage.success(`账号已封禁，并撤销 ${result.revokedSessions} 个登录会话`);
    await refreshAfterAction();
  } catch (error) {
    ElMessage.error(errorMessage(error, '用户封禁失败'));
  } finally {
    banSaving.value = false;
  }
}

async function saveUnban(removeKnownIps: boolean): Promise<void> {
  const user = selectedUser.value;
  if (!user || unbanSaving.value) return;
  unbanSaving.value = true;
  try {
    const result = await unbanUser(user.id, removeKnownIps);
    selectedUser.value = result.item;
    unbanOpen.value = false;
    const ipText = removeKnownIps ? `，并移除 ${result.removedIps} 条关联 IP 黑名单` : '，关联 IP 黑名单保持不变';
    ElMessage.success(`账号已解除封禁${ipText}`);
    await refreshAfterAction();
  } catch (error) {
    ElMessage.error(errorMessage(error, '用户解封失败'));
  } finally {
    unbanSaving.value = false;
  }
}

async function saveEconomy(payload: UserEconomyPayload): Promise<void> {
  const user = selectedUser.value;
  if (!user || economySaving.value) return;
  economySaving.value = true;
  try {
    const result = await adjustUserEconomy(user.id, payload);
    selectedUser.value = result.item;
    economyOpen.value = false;
    const asset = result.currency === 'coins' ? '樱花币' : '成长值';
    ElMessage.success(`${asset}已从 ${result.previousBalance.toLocaleString()} 调整为 ${result.nextBalance.toLocaleString()}，流水已记录`);
    await refreshAfterAction();
  } catch (error) {
    ElMessage.error(errorMessage(error, '人工账变失败'));
  } finally {
    economySaving.value = false;
  }
}

async function confirmRoleChange(user: AdminUser): Promise<void> {
  if (isCurrentAdmin(user)) {
    ElMessage.warning('不能修改当前登录账号自身的角色，请由其他管理员操作');
    return;
  }
  const nextRole: UserRole = user.role === 'admin' ? 'user' : 'admin';
  const action = nextRole === 'admin' ? '授予管理员权限' : '取消管理员权限';
  const effect = nextRole === 'admin'
    ? '该用户将可以进入全部后台模块并执行敏感操作。'
    : '该用户将失去后台管理权限。';
  try {
    await ElMessageBox.confirm(
      `${effect} 角色变更后，该账号的全部登录会话会被撤销，需要重新登录。`,
      `确认${action}？`,
      { type: 'warning', confirmButtonText: action, cancelButtonText: '取消' },
    );
    const result = await changeUserRole(user.id, nextRole);
    selectedUser.value = result.item;
    ElMessage.success(`${action}完成，已撤销 ${result.revokedSessions} 个登录会话`);
    await refreshAfterAction();
  } catch (error) {
    if (!isDialogCancel(error)) ElMessage.error(errorMessage(error, '角色修改失败'));
  }
}

async function confirmRevokeSessions(user: AdminUser): Promise<void> {
  if (isCurrentAdmin(user)) {
    ElMessage.warning('不能在这里撤销当前登录账号自身的会话');
    return;
  }
  try {
    await ElMessageBox.confirm(
      `将撤销“${user.nickname}”在所有设备上的有效登录，并断开聊天室在线连接；设备上报记录不会删除。`,
      '确认强制退出全部设备？',
      { type: 'warning', confirmButtonText: '撤销全部会话', cancelButtonText: '取消' },
    );
    const result = await revokeUserSessions(user.id);
    ElMessage.success(`已撤销 ${result.revokedSessions} 个会话，断开 ${result.disconnected} 个在线连接`);
    await refreshAfterAction();
  } catch (error) {
    if (!isDialogCancel(error)) ElMessage.error(errorMessage(error, '会话撤销失败'));
  }
}

async function refreshAfterAction(): Promise<void> {
  detailRefreshKey.value += 1;
  await loadUsers();
}

function syncSelectedUser(): void {
  if (!selectedUserId.value) return;
  const latest = items.value.find((item) => item.id === selectedUserId.value);
  if (latest) selectedUser.value = latest;
}

function isCurrentAdmin(user: AdminUser): boolean {
  return Number(session.user?.id || 0) === user.id;
}

function isRisky(user: AdminUser): boolean {
  return user.status === 'banned' || user.chatViolationTotal > 0 || user.stats.reported > 0;
}

function deviceSummary(user: AdminUser): string {
  if (!user.appInstall) return '未上报 App 版本';
  return `${user.appInstall.versionName || '未知版本'} · ${user.appInstall.platform || '未知平台'}`;
}

function versionOptionLabel(option: UserVersionOption): string {
  return `${option.versionName || `#${option.versionCode}`} · ${option.platform || '未知平台'} (${option.userCount})`;
}

function isDialogCancel(error: unknown): boolean {
  return error === 'cancel' || error === 'close';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="page-stack users-page">
    <section class="users-hero">
      <div class="hero-copy">
        <span class="eyebrow">USER OPERATIONS WORKBENCH</span>
        <h2>从账号全貌出发，再执行每一次敏感操作</h2>
        <p>资料、权限、设备、会话、社区风险与账变集中核查；封禁、角色和余额调整全部说明影响并留下可追溯记录。</p>
      </div>
      <div class="hero-health">
        <span class="health-ring" :style="{ '--rate': `${activeRate * 3.6}deg` }"><b>{{ activeRate }}%</b></span>
        <div><strong>账号正常率</strong><span>{{ stats.active.toLocaleString() }} 个账号可正常使用</span></div>
      </div>
    </section>

    <section class="metric-grid user-metric-grid">
      <MetricCard label="全部账号" :value="stats.total.toLocaleString()" :icon="UserFilled" hint="当前注册账号总量" />
      <MetricCard label="今日新增" :value="stats.newToday.toLocaleString()" :icon="User" tone="success" hint="按注册时间统计" />
      <MetricCard label="今日活跃" :value="stats.activeToday.toLocaleString()" :icon="Connection" tone="success" hint="今日产生登录活动" />
      <MetricCard label="风险关注" :value="stats.riskUsers.toLocaleString()" :icon="WarningFilled" :tone="stats.riskUsers ? 'warning' : 'success'" hint="违规、被举报或已封禁" />
      <MetricCard label="已封禁" :value="stats.banned.toLocaleString()" :icon="Lock" :tone="stats.banned ? 'danger' : 'default'" hint="含限时与永久封禁" />
      <MetricCard label="有效会话" :value="stats.activeSessions.toLocaleString()" :icon="Monitor" hint="可按账号集中撤销" />
    </section>

    <section class="status-strip" aria-label="账号状态快捷筛选">
      <button type="button" :class="{ active: query.status === '' }" @click="quickStatus('')">
        <span>全部账号</span><strong>{{ allStatusCount }}</strong><small>完整账号池</small>
      </button>
      <button type="button" :class="{ active: query.status === 'active' }" @click="quickStatus('active')">
        <span>正常使用</span><strong>{{ statusCounts.active || 0 }}</strong><small>登录与互动可用</small>
      </button>
      <button type="button" :class="{ active: query.status === 'banned' }" @click="quickStatus('banned')">
        <span>封禁中</span><strong>{{ statusCounts.banned || 0 }}</strong><small>可核查原因并解封</small>
      </button>
      <button type="button" :class="{ active: query.risk === 'chat_violations' }" @click="quickRisk('chat_violations')">
        <span>聊天违规</span><strong>{{ stats.chatViolationUsers }}</strong><small>点击聚焦违规账号</small>
      </button>
      <div class="role-summary">
        <span>角色分布</span>
        <div><small>普通用户 <b>{{ roleCounts.user || 0 }}</b></small><small>管理员 <b>{{ roleCounts.admin || 0 }}</b></small></div>
      </div>
    </section>

    <section class="users-workbench">
      <header class="workbench-toolbar">
        <div class="toolbar-copy">
          <h3>账号目录</h3>
          <p>当前筛选共 {{ total.toLocaleString() }} 个账号；点击账号进入完整档案与操作区。</p>
        </div>
        <div class="filter-row">
          <ElInput
            v-model="query.q"
            clearable
            class="search-input"
            placeholder="搜索 UID、邮箱、昵称或 IP"
            :prefix-icon="Search"
            @keyup.enter="searchUsers"
            @clear="searchUsers"
          />
          <ElSelect v-model="query.status" class="filter-select" placeholder="账号状态" @change="searchUsers">
            <ElOption label="全部状态" value="" /><ElOption label="正常" value="active" /><ElOption label="已封禁" value="banned" />
          </ElSelect>
          <ElSelect v-model="query.role" class="filter-select" placeholder="账号角色" @change="searchUsers">
            <ElOption label="全部角色" value="" /><ElOption label="普通用户" value="user" /><ElOption label="管理员" value="admin" />
          </ElSelect>
          <ElSelect v-model="query.risk" class="filter-select risk-select" placeholder="风险特征" @change="searchUsers">
            <ElOption label="全部风险" value="" /><ElOption label="有聊天违规" value="chat_violations" /><ElOption label="曾被举报" value="reported" /><ElOption label="未上报 App 版本" value="no_version" />
          </ElSelect>
          <ElSelect v-model="query.appVersionCode" filterable class="filter-select version-select" placeholder="App 版本" @change="searchUsers">
            <ElOption label="全部版本" value="" />
            <ElOption v-for="option in versionOptions" :key="`${option.versionCode}-${option.platform}`" :label="versionOptionLabel(option)" :value="option.versionCode" />
          </ElSelect>
          <ElSelect v-model="query.sort" class="filter-select sort-select" placeholder="排序" @change="searchUsers">
            <ElOption label="最新注册" value="newest" /><ElOption label="最近登录" value="recent" /><ElOption label="风险优先" value="risk" /><ElOption label="成长值最高" value="points" /><ElOption label="樱花币最多" value="coins" />
          </ElSelect>
          <ElButton type="primary" :icon="Search" @click="searchUsers">查询</ElButton>
          <ElButton :icon="Refresh" :loading="loading" @click="loadUsers">刷新</ElButton>
          <ElButton v-if="filterCount" text :icon="Filter" @click="resetFilters">清除 {{ filterCount }} 项筛选</ElButton>
        </div>
      </header>

      <div v-loading="loading" class="users-list">
        <div class="list-head user-grid" aria-hidden="true">
          <span>账号</span><span>角色 / 状态</span><span>成长与资产</span><span>设备与版本</span><span>活跃与风险</span><span>操作</span>
        </div>
        <article
          v-for="item in items"
          :key="item.id"
          class="user-row user-grid"
          :class="{ 'is-risky': isRisky(item), 'is-banned': item.status === 'banned' }"
          @dblclick="openDetail(item)"
        >
          <div class="identity-cell">
            <ElAvatar :src="item.avatarUrl" :size="44">{{ item.nickname?.slice(0, 1) || item.id }}</ElAvatar>
            <div>
              <span class="identity-title"><strong>{{ item.nickname || `用户 #${item.id}` }}</strong><b v-if="isCurrentAdmin(item)">当前账号</b></span>
              <small>{{ item.email }}</small>
              <span>UID {{ item.id }} · 注册 {{ formatDateTime(item.createdAt) }}</span>
            </div>
          </div>
          <div class="state-cell">
            <div><ElTag size="small" :type="item.status === 'active' ? 'success' : 'danger'">{{ userStatusLabel(item.status) }}</ElTag><ElTag size="small" :type="item.role === 'admin' ? 'warning' : 'info'" effect="plain">{{ userRoleLabel(item.role) }}</ElTag></div>
            <small v-if="item.status === 'banned'">{{ userBanReasonLabel(item.banReason) }}</small>
            <small v-else>{{ item.activeSessionCount }} 个有效会话</small>
          </div>
          <div class="economy-cell">
            <strong>Lv.{{ item.growth.level }} <small>{{ item.growth.levelName }}</small></strong>
            <span>成长值 <b>{{ item.growth.points.toLocaleString() }}</b></span>
            <span>樱花币 <b>{{ item.growth.sakuraCoins.toLocaleString() }}</b></span>
          </div>
          <div class="device-cell">
            <strong>{{ deviceSummary(item) }}</strong>
            <span>{{ item.appInstall?.deviceModel || '未记录设备型号' }}</span>
            <small>{{ item.deviceCount }} 台设备 · 最近 {{ formatDateTime(item.appInstall?.lastSeenAt || item.lastLoginAt) }}</small>
          </div>
          <div class="risk-cell">
            <strong :class="{ danger: isRisky(item) }">{{ userRiskLabel(item) }}</strong>
            <span>互动 {{ userActivityCount(item) }} · 被举报 {{ item.stats.reported }}</span>
            <small>聊天违规 {{ item.chatViolationTotal }} 次</small>
          </div>
          <div class="row-actions">
            <ElButton type="primary" plain size="small" :icon="View" @click="openDetail(item)">查看档案</ElButton>
          </div>
        </article>

        <div v-if="initialized && !loading && items.length === 0" class="friendly-empty list-empty">
          <ElIcon><User /></ElIcon><strong>没有符合条件的用户</strong><span>调整关键词或筛选条件后再试</span>
          <ElButton v-if="filterCount" size="small" @click="resetFilters">清除全部筛选</ElButton>
        </div>
      </div>

      <footer v-if="total > 0" class="pagination-row">
        <ElPagination
          background
          :current-page="query.page"
          :page-size="query.pageSize"
          :page-sizes="[10, 20, 50]"
          :pager-count="5"
          layout="total, sizes, prev, pager, next"
          :total="total"
          @current-change="changePage"
          @size-change="changePageSize"
        />
      </footer>
    </section>

    <UserDetailDrawer
      v-model="detailOpen"
      :user-id="selectedUserId"
      :current-user-id="session.user?.id"
      :refresh-key="detailRefreshKey"
      @edit-profile="openProfile"
      @ban-user="openBan"
      @unban-user="openUnban"
      @adjust-economy="openEconomy"
      @change-role="confirmRoleChange"
      @revoke-sessions="confirmRevokeSessions"
    />
    <UserProfileDialog v-model="profileOpen" :user="selectedUser" :saving="profileSaving" @submit="saveProfile" />
    <UserBanDialog v-model="banOpen" :user="selectedUser" :saving="banSaving" @submit="saveBan" />
    <UserUnbanDialog v-model="unbanOpen" :user="selectedUser" :saving="unbanSaving" @submit="saveUnban" />
    <UserEconomyDialog v-model="economyOpen" :user="selectedUser" :saving="economySaving" @submit="saveEconomy" />
  </div>
</template>

<style scoped>
.users-page { --user-grid: minmax(270px, 1.45fr) minmax(130px, .65fr) minmax(145px, .72fr) minmax(190px, 1fr) minmax(170px, .85fr) 112px; }
.users-hero { position: relative; overflow: hidden; display: flex; align-items: center; justify-content: space-between; gap: 28px; min-height: 176px; padding: 27px 31px; border: 1px solid #eadfe4; border-radius: 23px; background: radial-gradient(circle at 92% 4%, rgb(255 217 229 / 82%), transparent 32%), linear-gradient(135deg, #fff 0%, #fffafb 100%); box-shadow: 0 12px 35px rgb(83 44 64 / 6%); }.users-hero::after { position: absolute; right: 24%; bottom: -60px; width: 180px; height: 180px; border: 30px solid rgb(238 138 169 / 7%); border-radius: 50%; content: ''; }.hero-copy { position: relative; z-index: 1; }.hero-copy h2 { margin: 7px 0 8px; color: #352c31; font-size: clamp(22px, 2vw, 29px); }.hero-copy p { max-width: 780px; margin: 0; color: #806f76; font-size: 13px; line-height: 1.7; }.hero-health { position: relative; z-index: 1; display: flex; flex: 0 0 auto; align-items: center; gap: 13px; padding: 12px 15px; border: 1px solid rgb(231 210 218 / 82%); border-radius: 17px; background: rgb(255 255 255 / 78%); backdrop-filter: blur(9px); }.health-ring { --rate: 0deg; display: grid; width: 61px; height: 61px; place-items: center; border-radius: 50%; background: conic-gradient(#dc668b var(--rate), #f3e7eb 0); }.health-ring::before { grid-area: 1 / 1; width: 47px; height: 47px; border-radius: 50%; background: #fff; content: ''; }.health-ring b { z-index: 1; grid-area: 1 / 1; color: #a84665; font-size: 13px; }.hero-health > div { display: flex; flex-direction: column; gap: 4px; }.hero-health strong { color: #4b3940; font-size: 13px; }.hero-health span { color: #927d85; font-size: 10px; }
.status-strip { display: grid; grid-template-columns: repeat(4, minmax(125px, .72fr)) minmax(240px, 1.2fr); overflow: hidden; border: 1px solid #eae3e7; border-radius: 17px; background: white; box-shadow: 0 8px 25px rgb(57 39 50 / 4%); }.status-strip > button { display: flex; min-width: 0; flex-direction: column; align-items: flex-start; gap: 3px; padding: 15px 18px; border: 0; border-right: 1px solid #eee7ea; color: #806e75; background: white; text-align: left; transition: background 150ms ease, box-shadow 150ms ease; }.status-strip > button:hover { background: #fff8fa; }.status-strip > button.active { position: relative; z-index: 1; background: linear-gradient(145deg, #fff4f7, #fffafb); box-shadow: inset 0 -3px #dc668b; }.status-strip span { font-size: 10px; }.status-strip strong { color: #41343a; font-size: 20px; }.status-strip small { overflow: hidden; max-width: 100%; color: #9b8990; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }.role-summary { display: flex; flex-direction: column; justify-content: center; gap: 8px; padding: 13px 18px; }.role-summary > span { color: #907c84; font-size: 10px; }.role-summary > div { display: flex; flex-wrap: wrap; gap: 8px; }.role-summary small { padding: 6px 9px; border-radius: 8px; color: #80646e; background: #faf5f7; }.role-summary b { margin-left: 5px; color: #4d3941; }
.users-workbench { overflow: hidden; border: 1px solid #e9e3e6; border-radius: 18px; background: #fff; box-shadow: 0 10px 32px rgb(58 39 51 / 5%); }.workbench-toolbar { display: flex; align-items: flex-end; justify-content: space-between; gap: 20px; padding: 18px 20px; border-bottom: 1px solid #eee7ea; }.toolbar-copy { flex: 0 0 auto; }.toolbar-copy h3 { margin: 0; color: #403238; font-size: 16px; }.toolbar-copy p { margin: 5px 0 0; color: #927f87; font-size: 10px; }.filter-row { display: flex; flex: 1; flex-wrap: wrap; justify-content: flex-end; gap: 8px; }.search-input { width: 225px; }.filter-select { width: 115px; }.risk-select { width: 130px; }.version-select { width: 185px; }.sort-select { width: 118px; }
.users-list { min-height: 260px; }.user-grid { display: grid; grid-template-columns: var(--user-grid); align-items: center; gap: 14px; }.list-head { min-height: 39px; padding: 0 20px; color: #9e8c93; background: #faf8f9; font-size: 9px; font-weight: 700; letter-spacing: .05em; }.user-row { min-height: 91px; padding: 13px 20px; border-top: 1px solid #f0eaed; transition: background 140ms ease, box-shadow 140ms ease; }.list-head + .user-row { border-top: 0; }.user-row:hover { position: relative; background: #fffafb; box-shadow: inset 3px 0 #ef92ae; }.user-row.is-banned { background: #fffbfc; }.identity-cell { display: flex; min-width: 0; align-items: center; gap: 11px; }.identity-cell > div { display: flex; min-width: 0; flex-direction: column; gap: 3px; }.identity-title { display: flex; min-width: 0; align-items: center; gap: 6px; }.identity-title strong { overflow: hidden; color: #46383e; font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }.identity-title b { flex: 0 0 auto; padding: 2px 5px; border-radius: 5px; color: #b34869; background: #ffe8ef; font-size: 8px; }.identity-cell small { overflow: hidden; color: #806e75; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.identity-cell > div > span:last-child { color: #a08d94; font-size: 9px; }
.state-cell, .economy-cell, .device-cell, .risk-cell { display: flex; min-width: 0; flex-direction: column; gap: 4px; }.state-cell > div { display: flex; flex-wrap: wrap; gap: 5px; }.state-cell small, .device-cell span, .device-cell small, .risk-cell span, .risk-cell small { overflow: hidden; color: #98868d; font-size: 9px; text-overflow: ellipsis; white-space: nowrap; }.economy-cell > strong, .device-cell strong, .risk-cell strong { overflow: hidden; color: #4c3e44; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.economy-cell > strong small { color: #927f86; font-size: 9px; font-weight: 500; }.economy-cell span { color: #947f87; font-size: 9px; }.economy-cell b { margin-left: 3px; color: #5f4a52; }.risk-cell strong.danger { color: #c34e6e; }.row-actions { display: flex; justify-content: flex-end; }.list-empty { min-height: 240px; }
.pagination-row { display: flex; justify-content: flex-end; padding: 14px 20px; border-top: 1px solid #eee7ea; }
@media (max-width: 1460px) { .workbench-toolbar { align-items: flex-start; flex-direction: column; }.filter-row { justify-content: flex-start; }.users-page { --user-grid: minmax(250px, 1.35fr) 125px 140px minmax(170px, .9fr) minmax(155px, .8fr) 108px; } }
@media (max-width: 1320px) { .users-page { --user-grid: minmax(250px, 1.4fr) 130px 145px minmax(170px, 1fr) 108px; }.list-head > span:nth-child(5), .risk-cell { display: none; }.status-strip { grid-template-columns: repeat(4, 1fr); }.role-summary { display: none; } }
@media (max-width: 820px) { .users-hero { align-items: flex-start; flex-direction: column; }.hero-health { width: 100%; }.status-strip { grid-template-columns: 1fr 1fr; }.status-strip > button:nth-child(2n) { border-right: 0; }.status-strip > button:nth-child(-n + 2) { border-bottom: 1px solid #eee7ea; }.users-page { --user-grid: minmax(230px, 1.2fr) 125px minmax(150px, .8fr) 105px; }.list-head > span:nth-child(3), .economy-cell { display: none; }.search-input { width: min(100%, 300px); }.version-select { width: 180px; } }
@media (max-width: 620px) { .users-hero { padding: 23px 20px; }.hero-health { display: none; }.user-metric-grid { grid-template-columns: 1fr 1fr; }.filter-row > :deep(.el-input), .filter-row > :deep(.el-select) { width: calc(50% - 4px); }.filter-row > .search-input { width: 100%; }.filter-row :deep(.el-button) { margin-left: 0; }.list-head { display: none; }.user-row { display: flex; flex-wrap: wrap; gap: 12px; padding: 15px; }.identity-cell { width: 100%; }.state-cell, .device-cell { flex: 1 1 135px; }.row-actions { flex: 1 1 100%; }.row-actions :deep(.el-button) { width: 100%; }.pagination-row { overflow-x: auto; justify-content: flex-start; }.status-strip strong { font-size: 17px; } }
</style>
