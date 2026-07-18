<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { Bell, ChatDotRound, Coin, DataAnalysis, Flag, MagicStick, Refresh, User } from '@element-plus/icons-vue';

import MetricCard from '@/components/MetricCard.vue';
import SectionCard from '@/components/SectionCard.vue';
import { apiRequest } from '@/services/api';
import { formatBytes, formatCompactNumber, formatDateTime, formatDuration } from '@/utils/format';

interface DashboardSummary {
  recentReports?: Array<Record<string, unknown>>;
  activeCommentTargets?: Array<Record<string, unknown>>;
  activeDanmakuGroups?: Array<Record<string, unknown>>;
  activeChatRooms?: Array<Record<string, unknown>>;
}

interface OperationsOverview {
  service?: Record<string, unknown>;
  users?: Record<string, unknown>;
  content?: Record<string, unknown>;
  economy24h?: Record<string, unknown>;
  race?: Record<string, unknown>;
  recentAudit?: Array<Record<string, unknown>>;
  recentBroadcasts?: Array<Record<string, unknown>>;
}

const router = useRouter();
const loading = ref(true);
const error = ref('');
const summary = ref<DashboardSummary>({});
const operations = ref<OperationsOverview>({});
const aiPendingCount = ref(0);

const service = computed(() => operations.value.service || {});
const users = computed(() => operations.value.users || {});
const content = computed(() => operations.value.content || {});
const economy = computed(() => operations.value.economy24h || {});
const race = computed(() => operations.value.race || {});
const content24h = computed(() =>
  Number(content.value.comments24h || 0) +
  Number(content.value.danmaku24h || 0) +
  Number(content.value.chat24h || 0),
);

const taskCards = computed(() => [
  {
    label: '待处理举报',
    value: Number(content.value.openReports || 0),
    hint: '优先处理涉及用户安全的举报',
    route: 'reports',
    icon: Flag,
    tone: Number(content.value.openReports || 0) > 0 ? 'danger' : 'default',
  },
  {
    label: 'AI 小说审核',
    value: aiPendingCount.value,
    hint: '作品和连载章节统一审核',
    route: 'ai-novels',
    icon: MagicStick,
    tone: aiPendingCount.value > 0 ? 'danger' : 'default',
  },
  {
    label: '社区内容',
    value: formatCompactNumber(content24h.value),
    hint: '过去 24 小时新增互动',
    route: 'comments',
    icon: ChatDotRound,
    tone: 'default',
  },
] as const);

async function load(): Promise<void> {
  loading.value = true;
  error.value = '';
  try {
    const [summaryData, operationsData, pendingNovels, pendingChapters] = await Promise.all([
      apiRequest<DashboardSummary>('/admin/summary'),
      apiRequest<OperationsOverview>('/admin/operations/overview'),
      apiRequest<{ total: number }>('/admin/ai-novels?status=pending&page=1&pageSize=1'),
      apiRequest<{ total: number }>('/admin/ai-novel-chapters?status=pending&page=1&pageSize=1'),
    ]);
    summary.value = summaryData;
    operations.value = operationsData;
    aiPendingCount.value = Number(pendingNovels.total || 0) + Number(pendingChapters.total || 0);
  } catch (loadError) {
    error.value = loadError instanceof Error ? loadError.message : '总览加载失败';
  } finally {
    loading.value = false;
  }
}

onMounted(load);
</script>

<template>
  <div class="page-stack dashboard-page">
    <div class="page-action-row">
      <div>
        <span class="eyebrow">TODAY'S OVERVIEW</span>
        <h2>今天需要关注什么</h2>
        <p>先处理风险和待审核任务，再观察业务与服务健康。</p>
      </div>
      <ElButton :icon="Refresh" :loading="loading" @click="load">刷新数据</ElButton>
    </div>

    <ElAlert v-if="error" :title="error" type="error" show-icon :closable="false">
      <template #default><ElButton text type="primary" @click="load">重新加载</ElButton></template>
    </ElAlert>

    <ElSkeleton v-if="loading" :rows="8" animated />
    <template v-else>
      <section class="metric-grid">
        <MetricCard label="24h 活跃用户" :value="formatCompactNumber(users.active24h)" :hint="`总用户 ${formatCompactNumber(users.total)}`" :icon="User" />
        <MetricCard label="24h 新用户" :value="formatCompactNumber(users.new24h)" :hint="`${formatCompactNumber(users.banned)} 个封禁账号`" :icon="User" />
        <MetricCard label="24h 社区内容" :value="formatCompactNumber(content24h)" hint="评论、弹幕与聊天" :icon="ChatDotRound" />
        <MetricCard label="待处理举报" :value="formatCompactNumber(content.openReports)" hint="需要人工确认" :icon="Flag" :tone="Number(content.openReports || 0) ? 'danger' : 'success'" />
        <MetricCard label="24h 资金事件" :value="formatCompactNumber(economy.event_count)" :hint="`发放 ${economy.coins_issued || 0} / 消耗 ${economy.coins_spent || 0}`" :icon="Coin" />
        <MetricCard label="赛马投注额" :value="formatCompactNumber(race.staked24h)" :hint="`${race.participants24h || 0} 位参与者`" :icon="DataAnalysis" />
      </section>

      <section class="task-grid">
        <button v-for="task in taskCards" :key="task.label" class="task-card" type="button" @click="router.push({ name: task.route })">
          <span class="task-icon" :class="`tone-${task.tone}`"><ElIcon><component :is="task.icon" /></ElIcon></span>
          <span class="task-copy"><strong>{{ task.label }}</strong><small>{{ task.hint }}</small></span>
          <b>{{ task.value }}</b>
        </button>
      </section>

      <section class="dashboard-columns">
        <SectionCard title="服务健康" hint="当前 Node 进程与数据存储状态">
          <div class="health-list">
            <div><span>服务状态</span><strong class="status-online">{{ service.status || 'unknown' }}</strong></div>
            <div><span>运行时间</span><strong>{{ formatDuration(service.uptimeSeconds) }}</strong></div>
            <div><span>进程内存</span><strong>{{ formatBytes(service.processMemoryBytes) }}</strong></div>
            <div><span>数据库体积</span><strong>{{ formatBytes(service.dbBytes) }}</strong></div>
            <div><span>Node 版本</span><strong>{{ service.nodeVersion || '—' }}</strong></div>
            <div><span>运行平台</span><strong>{{ service.platform || '—' }}</strong></div>
          </div>
        </SectionCard>

        <SectionCard title="最近待处理举报" hint="这里只展示最需要立即关注的任务">
          <div v-if="summary.recentReports?.length" class="activity-list">
            <button v-for="item in summary.recentReports" :key="String(item.id)" type="button" @click="router.push({ name: 'reports' })">
              <span><strong>{{ item.reason || '未填写原因' }}</strong><small>{{ item.targetType }} #{{ item.targetId }}</small></span>
              <time>{{ formatDateTime(item.createdAt || item.created_at) }}</time>
            </button>
          </div>
          <div v-else class="friendly-empty"><ElIcon><Flag /></ElIcon><strong>没有待处理举报</strong><span>当前举报队列已清空</span></div>
        </SectionCard>
      </section>

      <section class="dashboard-columns">
        <SectionCard title="最近管理员操作" hint="敏感写操作都会进入审计">
          <div v-if="operations.recentAudit?.length" class="activity-list">
            <div v-for="item in operations.recentAudit" :key="String(item.id || `${item.path}-${item.created_at}`)">
              <span><strong>{{ item.method || '—' }} {{ item.path || '—' }}</strong><small>{{ item.nickname || item.email || '系统' }}</small></span>
              <time>{{ formatDateTime(item.created_at) }}</time>
            </div>
          </div>
          <div v-else class="friendly-empty"><strong>暂无审计记录</strong></div>
        </SectionCard>

        <SectionCard title="最近通知发布" hint="发送对象和发布时间均可追踪">
          <div v-if="operations.recentBroadcasts?.length" class="activity-list">
            <div v-for="item in operations.recentBroadcasts" :key="String(item.id || `${item.title}-${item.created_at}`)">
              <span><strong>{{ item.title || '系统通知' }}</strong><small>{{ item.recipient_count || 0 }} 位接收者</small></span>
              <time>{{ formatDateTime(item.created_at) }}</time>
            </div>
          </div>
          <div v-else class="friendly-empty"><ElIcon><Bell /></ElIcon><strong>暂无发布记录</strong></div>
        </SectionCard>
      </section>
    </template>
  </div>
</template>
