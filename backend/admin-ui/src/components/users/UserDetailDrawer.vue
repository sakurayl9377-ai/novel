<script setup lang="ts">
import {
  ChatDotRound,
  Coin,
  Connection,
  DataLine,
  EditPen,
  Flag,
  Lock,
  Monitor,
  Refresh,
  Tickets,
  User,
  VideoCamera,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { getUserDetail } from '@/services/users';
import type { AdminUser, UserDetailResponse } from '@/types/user';
import { chatViolationActionLabel } from '@/utils/chat';
import { formatDateTime } from '@/utils/format';
import { reportStatusLabel, reportStatusTone } from '@/utils/moderation';
import {
  maskInstallId,
  rewardActionLabel,
  signedNumber,
  userBanReasonLabel,
  userGenderLabel,
  userRiskLabel,
  userRoleLabel,
  userStatusLabel,
} from '@/utils/users';

const props = defineProps<{
  modelValue: boolean;
  userId: number | null;
  currentUserId?: number;
  refreshKey?: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'edit-profile': [user: AdminUser];
  'ban-user': [user: AdminUser];
  'unban-user': [user: AdminUser];
  'adjust-economy': [user: AdminUser];
  'change-role': [user: AdminUser];
  'revoke-sessions': [user: AdminUser];
}>();

const loading = ref(false);
const detail = ref<UserDetailResponse | null>(null);
const activeTab = ref('overview');
const activityTab = ref('violations');
const profileCollapse = ref<string[]>(['profile']);

const user = computed(() => detail.value?.user || null);
const isCurrentAccount = computed(() => Boolean(
  user.value && props.currentUserId && user.value.id === props.currentUserId,
));
const riskTone = computed(() => {
  if (!user.value) return 'normal';
  if (user.value.status === 'banned' || user.value.chatViolationTotal >= 5) return 'high';
  if (user.value.chatViolationTotal || user.value.stats.reported) return 'attention';
  return 'normal';
});

watch(
  () => [props.modelValue, props.userId, props.refreshKey] as const,
  ([open]) => {
    if (open && props.userId) void loadDetail();
  },
);

async function loadDetail(): Promise<void> {
  if (!props.userId) return;
  loading.value = true;
  try {
    detail.value = await getUserDetail(props.userId);
  } catch (error) {
    ElMessage.error(errorMessage(error, '用户详情加载失败'));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(900px, 97vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="user-drawer-heading">
        <ElAvatar :src="user?.avatarUrl" :size="50">{{ user?.nickname?.slice(0, 1) }}</ElAvatar>
        <div>
          <span>USER OPERATIONS</span>
          <h2>{{ user?.nickname || '用户详情' }}</h2>
          <p v-if="user">{{ user.email }} · UID {{ user.id }}</p>
        </div>
        <div v-if="user" class="heading-tags">
          <ElTag :type="user.status === 'active' ? 'success' : 'danger'">{{ userStatusLabel(user.status) }}</ElTag>
          <ElTag :type="user.role === 'admin' ? 'warning' : 'info'" effect="plain">{{ userRoleLabel(user.role) }}</ElTag>
        </div>
      </div>
    </template>

    <div v-loading="loading" class="detail-body">
      <template v-if="detail && user">
        <section class="risk-banner" :class="riskTone">
          <span class="risk-icon"><ElIcon><WarningFilled /></ElIcon></span>
          <div><strong>{{ userRiskLabel(user) }}</strong><p>聊天违规 {{ user.chatViolationTotal }} 次 · 被举报 {{ user.stats.reported }} 次 · 临时封禁累计 {{ user.chatTempBanCount }} 次</p></div>
          <span v-if="user.status === 'banned'" class="ban-reason">{{ userBanReasonLabel(user.banReason) }}</span>
        </section>

        <section class="user-metrics">
          <div><span>等级</span><strong>Lv.{{ user.growth.level }}</strong><small>{{ user.growth.levelName }}</small></div>
          <div><span>成长值</span><strong>{{ user.growth.points.toLocaleString() }}</strong><small>下级 {{ user.growth.nextLevelPoints.toLocaleString() }}</small></div>
          <div><span>樱花币</span><strong>{{ user.growth.sakuraCoins.toLocaleString() }}</strong><small>账变可追溯</small></div>
          <div><span>设备</span><strong>{{ user.deviceCount }}</strong><small>{{ user.appInstall?.versionName || '未上报版本' }}</small></div>
          <div><span>有效会话</span><strong>{{ user.activeSessionCount }}</strong><small>可一键撤销</small></div>
          <div><span>社区互动</span><strong>{{ user.stats.comments + user.stats.danmaku + user.stats.chat }}</strong><small>评论 / 弹幕 / 聊天</small></div>
        </section>

        <div class="primary-actions">
          <ElButton :icon="EditPen" @click="emit('edit-profile', user)">编辑资料</ElButton>
          <ElButton type="primary" plain :icon="Coin" @click="emit('adjust-economy', user)">人工账变</ElButton>
          <ElButton :icon="User" :disabled="isCurrentAccount" @click="emit('change-role', user)">{{ user.role === 'admin' ? '取消管理员' : '设为管理员' }}</ElButton>
          <ElButton v-if="user.status === 'active'" type="danger" plain :icon="Lock" :disabled="isCurrentAccount" @click="emit('ban-user', user)">封禁用户</ElButton>
          <ElButton v-else type="success" plain :icon="Refresh" @click="emit('unban-user', user)">解除封禁</ElButton>
          <span v-if="isCurrentAccount" class="self-protection-note">当前登录账号不能封禁、改角色或撤销自身会话</span>
        </div>

        <ElTabs v-model="activeTab" class="detail-tabs">
          <ElTabPane name="overview" label="账号概览">
            <ElCollapse v-model="profileCollapse" class="detail-collapse">
              <ElCollapseItem name="profile">
                <template #title><span class="collapse-title"><ElIcon><User /></ElIcon>公开资料与账号信息</span></template>
                <dl class="profile-grid">
                  <div><dt>昵称</dt><dd>{{ user.nickname }}</dd></div>
                  <div><dt>性别展示</dt><dd>{{ userGenderLabel(user.gender) }}</dd></div>
                  <div><dt>注册时间</dt><dd>{{ formatDateTime(user.createdAt) }}</dd></div>
                  <div><dt>最近登录</dt><dd>{{ formatDateTime(user.lastLoginAt) }}</dd></div>
                  <div><dt>注册 IP</dt><dd>{{ user.registerIp || '未记录' }}</dd></div>
                  <div><dt>最近登录 IP</dt><dd>{{ user.lastLoginIp || '未记录' }}</dd></div>
                  <div class="wide"><dt>个性签名</dt><dd>{{ user.signature || '未填写' }}</dd></div>
                  <div class="wide"><dt>个人简介</dt><dd>{{ user.bio || '未填写' }}</dd></div>
                </dl>
              </ElCollapseItem>
              <ElCollapseItem name="privileges">
                <template #title><span class="collapse-title"><ElIcon><DataLine /></ElIcon>已解锁权益</span></template>
                <div class="privilege-list">
                  <span
                    v-for="permission in user.growth.effects.filter((item) => item.unlocked).flatMap((item) => item.permissions)"
                    :key="permission"
                  >{{ permission }}</span>
                </div>
              </ElCollapseItem>
            </ElCollapse>
          </ElTabPane>

          <ElTabPane name="security" label="安全与封禁">
            <section v-if="user.status === 'banned'" class="ban-state-card">
              <div><span>当前封禁原因</span><strong>{{ userBanReasonLabel(user.banReason) }}</strong></div>
              <div><span>自动解封时间</span><strong>{{ user.bannedUntil ? formatDateTime(user.bannedUntil) : '永久封禁' }}</strong></div>
            </section>
            <div class="security-heading">
              <div><h3>登录会话</h3><p>撤销后所有设备都需要重新登录，不会删除设备上报记录。</p></div>
              <ElButton type="danger" plain :disabled="!detail.sessions.activeCount || isCurrentAccount" @click="emit('revoke-sessions', user)">撤销全部有效会话</ElButton>
            </div>
            <div class="session-list">
              <article v-for="session in detail.sessions.items" :key="session.id">
                <span class="session-icon"><ElIcon><Connection /></ElIcon></span>
                <div><strong>会话 #{{ session.id }}</strong><span>创建 {{ formatDateTime(session.createdAt) }} · 到期 {{ formatDateTime(session.expiresAt) }}</span></div>
                <ElTag :type="session.active ? 'success' : 'info'" size="small">{{ session.active ? '有效' : session.revokedAt ? '已撤销' : '已过期' }}</ElTag>
              </article>
              <ElEmpty v-if="!detail.sessions.items.length" :image-size="62" description="没有登录会话记录" />
            </div>
            <div class="security-heading ip-heading"><div><h3>关联注册 IP 黑名单</h3><p>这里只展示与该用户关联的条目。</p></div></div>
            <div class="blocked-ip-list">
              <span v-for="item in detail.blockedIps" :key="item.ip"><b>{{ item.ip }}</b>{{ userBanReasonLabel(item.reason) }}</span>
              <p v-if="!detail.blockedIps.length">没有关联的注册 IP 黑名单</p>
            </div>
          </ElTabPane>

          <ElTabPane name="devices" label="App 与设备">
            <div class="device-list">
              <article v-for="device in detail.devices" :key="device.id">
                <span class="device-icon"><ElIcon><Monitor /></ElIcon></span>
                <div class="device-main">
                  <div><strong>{{ device.deviceModel || '未知设备' }}</strong><ElTag size="small" effect="plain">{{ device.platform || '未知平台' }}</ElTag></div>
                  <span>{{ device.versionName || '未知版本' }} (#{{ device.versionCode }}) · {{ device.osVersion || '未知系统' }}</span>
                  <small>安装 {{ maskInstallId(device.installId) }} · IP {{ device.lastIp || '未记录' }}</small>
                </div>
                <div class="device-time"><span>首次 {{ formatDateTime(device.firstSeenAt) }}</span><b>最近 {{ formatDateTime(device.lastSeenAt) }}</b></div>
              </article>
              <ElEmpty v-if="!detail.devices.length" description="尚未上报 App 或设备信息" />
            </div>
          </ElTabPane>

          <ElTabPane name="activity" label="内容与风险记录">
            <ElTabs v-model="activityTab" class="activity-tabs">
              <ElTabPane name="violations" :label="`聊天违规 ${detail.violations.length}`">
                <div class="activity-list">
                  <article v-for="item in detail.violations" :key="item.id">
                    <span class="activity-icon danger"><ElIcon><WarningFilled /></ElIcon></span>
                    <div><strong>{{ item.content }}</strong><span>命中 {{ item.keyword || '已删除规则' }} · {{ item.roomId }} · {{ item.ip || '无 IP' }}</span></div>
                    <div><ElTag :type="item.action === 'blocked' ? 'warning' : 'danger'" size="small">{{ chatViolationActionLabel(item.action) }}</ElTag><small>{{ formatDateTime(item.createdAt) }}</small></div>
                  </article>
                  <ElEmpty v-if="!detail.violations.length" :image-size="62" description="没有聊天违规记录" />
                </div>
              </ElTabPane>
              <ElTabPane name="reports" :label="`举报 ${detail.reports.length + detail.reportsAgainst.length}`">
                <div class="activity-list">
                  <article v-for="item in [...detail.reportsAgainst, ...detail.reports]" :key="item.id">
                    <span class="activity-icon"><ElIcon><Flag /></ElIcon></span>
                    <div><strong>{{ item.reason }}</strong><span>{{ item.targetType === 'user' ? '该用户被举报' : '该用户发起举报' }} · 目标 {{ item.targetType }} #{{ item.targetId }}</span></div>
                    <div><ElTag :type="reportStatusTone(item.status)" size="small">{{ reportStatusLabel(item.status) }}</ElTag><small>{{ formatDateTime(item.createdAt) }}</small></div>
                  </article>
                  <ElEmpty v-if="!detail.reports.length && !detail.reportsAgainst.length" :image-size="62" description="没有举报记录" />
                </div>
              </ElTabPane>
              <ElTabPane name="comments" :label="`评论 ${detail.comments.length}`">
                <div class="activity-list"><article v-for="item in detail.comments" :key="item.id"><span class="activity-icon"><ElIcon><Tickets /></ElIcon></span><div><strong>{{ item.content }}</strong><span>{{ item.targetType }} · {{ formatDateTime(item.createdAt) }}</span></div><ElTag :type="item.status === 'visible' ? 'success' : 'info'" size="small">{{ item.status === 'visible' ? '展示中' : '已删除' }}</ElTag></article><ElEmpty v-if="!detail.comments.length" :image-size="62" description="没有评论记录" /></div>
              </ElTabPane>
              <ElTabPane name="danmaku" :label="`弹幕 ${detail.danmaku.length}`">
                <div class="activity-list"><article v-for="item in detail.danmaku" :key="item.id"><span class="activity-icon"><ElIcon><VideoCamera /></ElIcon></span><div><strong>{{ item.content }}</strong><span>{{ item.videoId }} · {{ formatDateTime(item.createdAt) }}</span></div><ElTag :type="item.status === 'visible' ? 'success' : 'info'" size="small">{{ item.status === 'visible' ? '展示中' : '已删除' }}</ElTag></article><ElEmpty v-if="!detail.danmaku.length" :image-size="62" description="没有弹幕记录" /></div>
              </ElTabPane>
              <ElTabPane name="chat" :label="`聊天 ${detail.chat.length}`">
                <div class="activity-list"><article v-for="item in detail.chat" :key="item.id"><span class="activity-icon"><ElIcon><ChatDotRound /></ElIcon></span><div><strong>{{ item.content }}</strong><span>{{ item.roomId }} · {{ formatDateTime(item.createdAt) }}</span></div><ElTag :type="item.status === 'visible' ? 'success' : 'info'" size="small">{{ item.status === 'visible' ? '展示中' : '已删除' }}</ElTag></article><ElEmpty v-if="!detail.chat.length" :image-size="62" description="没有聊天记录" /></div>
              </ElTabPane>
            </ElTabs>
          </ElTabPane>

          <ElTabPane name="economy" label="成长与账变">
            <div class="economy-heading"><div><h3>最近账变流水</h3><p>人工调整和系统奖励统一按时间倒序展示。</p></div><ElButton type="primary" :icon="Coin" @click="emit('adjust-economy', user)">新增人工账变</ElButton></div>
            <div class="reward-list">
              <article v-for="item in detail.rewardEvents" :key="item.id">
                <span class="reward-icon"><ElIcon><Coin /></ElIcon></span>
                <div><strong>{{ rewardActionLabel(item.action) }}</strong><span>{{ item.description || '无说明' }} · {{ formatDateTime(item.createdAt) }}</span></div>
                <div class="reward-deltas"><b v-if="item.pointsDelta" :class="{ debit: item.pointsDelta < 0 }">成长值 {{ signedNumber(item.pointsDelta) }}</b><b v-if="item.coinsDelta" :class="{ debit: item.coinsDelta < 0 }">樱花币 {{ signedNumber(item.coinsDelta) }}</b></div>
              </article>
              <ElEmpty v-if="!detail.rewardEvents.length" :image-size="62" description="没有账变记录" />
            </div>
          </ElTabPane>
        </ElTabs>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.user-drawer-heading { display: flex; align-items: center; gap: 12px; width: 100%; }.user-drawer-heading > div:nth-child(2) { min-width: 0; }.user-drawer-heading > div:nth-child(2) > span { color: #c45d82; font-size: 9px; font-weight: 800; letter-spacing: .14em; }.user-drawer-heading h2 { margin: 2px 0; color: #3e3137; font-size: 21px; }.user-drawer-heading p { margin: 0; overflow: hidden; color: #907d84; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.heading-tags { display: flex; margin-left: auto; gap: 6px; }
.detail-body { min-height: 320px; }.risk-banner { display: flex; align-items: center; gap: 11px; padding: 13px 15px; border: 1px solid #dceee3; border-radius: 15px; background: #f6fcf8; }.risk-banner.attention { border-color: #f1e1bd; background: #fffbf2; }.risk-banner.high { border-color: #f1cbd3; background: #fff5f7; }.risk-icon { display: grid; flex: 0 0 38px; width: 38px; height: 38px; place-items: center; border-radius: 12px; color: #5a9871; background: #dff3e6; }.attention .risk-icon { color: #b27c29; background: #ffedc8; }.high .risk-icon { color: #cf5674; background: #ffe2e9; }.risk-banner > div { flex: 1; }.risk-banner strong { color: #483a40; }.risk-banner p { margin: 3px 0 0; color: #927e86; font-size: 11px; }.ban-reason { max-width: 220px; color: #b34f68; font-size: 11px; text-align: right; }
.user-metrics { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 8px; margin: 13px 0; }.user-metrics div { display: flex; min-width: 0; flex-direction: column; gap: 3px; padding: 11px; border-radius: 13px; background: #faf7f8; }.user-metrics span, .user-metrics small { overflow: hidden; color: #9a868e; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.user-metrics strong { color: #4a3b41; font-size: 17px; }
.primary-actions { display: flex; flex-wrap: wrap; align-items: center; justify-content: flex-end; gap: 7px; padding-bottom: 13px; border-bottom: 1px solid #eee2e6; }.self-protection-note { width: 100%; color: #9d7884; font-size: 9px; text-align: right; }.detail-tabs :deep(.el-tabs__item) { font-weight: 650; }.detail-collapse { border-top: 0; }.collapse-title { display: inline-flex; align-items: center; gap: 7px; color: #534249; font-weight: 650; }.profile-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 9px; margin: 0; }.profile-grid div { padding: 10px; border-radius: 11px; background: #faf7f8; }.profile-grid .wide { grid-column: span 3; }.profile-grid dt { color: #99858d; font-size: 10px; }.profile-grid dd { margin: 4px 0 0; overflow-wrap: anywhere; color: #4d3e44; font-size: 12px; }.privilege-list { display: flex; flex-wrap: wrap; gap: 6px; }.privilege-list span { padding: 6px 9px; border-radius: 9px; color: #8a5b6c; background: #fff0f5; font-size: 10px; }
.ban-state-card { display: grid; grid-template-columns: 1fr 1fr; gap: 9px; margin-bottom: 14px; }.ban-state-card div { display: flex; flex-direction: column; gap: 4px; padding: 12px; border-radius: 12px; background: #fff1f4; }.ban-state-card span { color: #a27883; font-size: 10px; }.ban-state-card strong { color: #a7445e; }.security-heading, .economy-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; margin: 10px 0; }.security-heading h3, .economy-heading h3 { margin: 0; color: #47383e; }.security-heading p, .economy-heading p { margin: 3px 0 0; color: #948088; font-size: 11px; }.ip-heading { margin-top: 20px; }.session-list, .device-list, .activity-list, .reward-list { display: grid; gap: 8px; }.session-list article, .device-list article, .activity-list article, .reward-list article { display: flex; align-items: center; gap: 11px; padding: 12px; border: 1px solid #eee3e7; border-radius: 13px; background: #fff; }.session-icon, .device-icon, .activity-icon, .reward-icon { display: grid; flex: 0 0 36px; width: 36px; height: 36px; place-items: center; border-radius: 11px; color: #7186ae; background: #edf2fb; }.activity-icon.danger { color: #c95573; background: #ffe7ec; }.session-list article > div, .activity-list article > div:nth-child(2), .reward-list article > div:nth-child(2) { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }.session-list strong, .activity-list strong, .reward-list strong { overflow: hidden; color: #4d3d44; text-overflow: ellipsis; white-space: nowrap; }.session-list span, .activity-list span, .reward-list span { overflow: hidden; color: #96828a; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.blocked-ip-list { display: flex; flex-wrap: wrap; gap: 7px; }.blocked-ip-list > span { display: flex; flex-direction: column; gap: 2px; padding: 8px 10px; border-radius: 10px; color: #9b6d78; background: #fff2f5; font-size: 9px; }.blocked-ip-list b { color: #a6415d; font-size: 11px; }.blocked-ip-list p { color: #9b878f; font-size: 11px; }
.device-main { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }.device-main > div { display: flex; align-items: center; gap: 6px; }.device-main strong { color: #4a3a41; }.device-main > span, .device-main small { overflow: hidden; color: #927e86; font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.device-time { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; color: #9a878e; font-size: 9px; }.device-time b { color: #6e5962; font-weight: 600; }.activity-tabs :deep(.el-tabs__item) { font-size: 12px; }.activity-list article > div:last-child { display: flex; flex: 0 0 auto; flex-direction: column; align-items: flex-end; gap: 4px; }.activity-list small { color: #a18e95; }.reward-deltas { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; }.reward-deltas b { color: #3d9662; font-size: 11px; }.reward-deltas b.debit { color: #d05570; }
@media (max-width: 760px) { .user-metrics { grid-template-columns: repeat(3, minmax(0, 1fr)); }.profile-grid { grid-template-columns: 1fr 1fr; }.profile-grid .wide { grid-column: span 2; }.device-time { width: 100%; align-items: flex-start; }.device-list article { flex-wrap: wrap; } }
@media (max-width: 520px) { .heading-tags { display: none; }.risk-banner { align-items: flex-start; }.ban-reason { display: none; }.user-metrics { grid-template-columns: 1fr 1fr; }.profile-grid { grid-template-columns: 1fr; }.profile-grid .wide { grid-column: span 1; }.primary-actions .el-button { flex: 1; }.security-heading, .economy-heading { align-items: flex-start; flex-direction: column; }.activity-list article { align-items: flex-start; flex-wrap: wrap; }.activity-list article > div:last-child { width: 100%; flex-direction: row; justify-content: space-between; align-items: center; } }
</style>
