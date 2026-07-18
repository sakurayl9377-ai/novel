<script setup lang="ts">
import {
  ChatLineRound,
  CircleCheck,
  Delete,
  Flag,
  Refresh,
  Search,
  Tickets,
  View,
  Warning,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import CommentContextDrawer from '@/components/moderation/CommentContextDrawer.vue';
import ReportDetailDrawer from '@/components/moderation/ReportDetailDrawer.vue';
import {
  listComments,
  listReports,
  resolveReportAndDeleteTarget,
  updateCommentStatus,
  updateReportStatus,
} from '@/services/moderation';
import type {
  CommentItem,
  CommentStatus,
  CountItem,
  ReportItem,
  ReportStatus,
} from '@/types/moderation';
import { formatDateTime } from '@/utils/format';
import {
  commentStatusLabel,
  contentTargetLabel,
  reportPreviewText,
  reportStatusLabel,
  reportStatusTone,
  reportTargetLabel,
} from '@/utils/moderation';

const route = useRoute();
const router = useRouter();

const commentLoading = ref(false);
const reportLoading = ref(false);
const rowUpdatingId = ref<number | null>(null);
const reportProcessing = ref(false);
const commentItems = ref<CommentItem[]>([]);
const reportItems = ref<ReportItem[]>([]);
const commentTotal = ref(0);
const reportTotal = ref(0);
const commentStatusCounts = ref<Record<string, number>>({});
const reportStatusCounts = ref<Record<string, number>>({});
const commentTargetCounts = ref<CountItem[]>([]);
const reportTargetCounts = ref<CountItem[]>([]);

const commentDrawerOpen = ref(false);
const selectedCommentId = ref<number | null>(null);
const reportDrawerOpen = ref(false);
const selectedReport = ref<ReportItem | null>(null);

const commentQuery = reactive({
  q: '',
  status: '' as '' | CommentStatus,
  targetType: '',
  page: 1,
  pageSize: 20,
});

const reportQuery = reactive({
  q: '',
  status: 'open' as '' | ReportStatus,
  targetType: '',
  page: 1,
  pageSize: 20,
});

const activeMode = computed<'comments' | 'reports'>(() =>
  route.name === 'reports' ? 'reports' : 'comments',
);
const allCommentCount = computed(() => Object.values(commentStatusCounts.value)
  .reduce((sum, count) => sum + Number(count || 0), 0));
const openReportCount = computed(() => Number(reportStatusCounts.value.open || 0));

onMounted(async () => {
  await Promise.all([loadComments(), loadReports()]);
});

async function loadComments(): Promise<void> {
  commentLoading.value = true;
  try {
    const data = await listComments(commentQuery);
    commentItems.value = data.items;
    commentTotal.value = data.total;
    commentStatusCounts.value = data.statusCounts;
    commentTargetCounts.value = data.targetCounts;
  } catch (error) {
    ElMessage.error(errorMessage(error, '评论列表加载失败'));
  } finally {
    commentLoading.value = false;
  }
}

async function loadReports(): Promise<void> {
  reportLoading.value = true;
  try {
    const data = await listReports(reportQuery);
    reportItems.value = data.items;
    reportTotal.value = data.total;
    reportStatusCounts.value = data.statusCounts;
    reportTargetCounts.value = data.targetCounts;
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报队列加载失败'));
  } finally {
    reportLoading.value = false;
  }
}

function switchMode(value: string | number): void {
  const name = String(value) === 'reports' ? 'reports' : 'comments';
  if (route.name !== name) void router.push({ name });
}

function searchComments(): void {
  commentQuery.page = 1;
  void loadComments();
}

function searchReports(): void {
  reportQuery.page = 1;
  void loadReports();
}

function filterComments(status: '' | CommentStatus): void {
  commentQuery.status = status;
  commentQuery.page = 1;
  void loadComments();
}

function filterReports(status: '' | ReportStatus): void {
  reportQuery.status = status;
  reportQuery.page = 1;
  void loadReports();
}

function changeCommentPage(page: number): void {
  commentQuery.page = page;
  void loadComments();
}

function changeCommentPageSize(pageSize: number): void {
  commentQuery.pageSize = pageSize;
  commentQuery.page = 1;
  void loadComments();
}

function changeReportPage(page: number): void {
  reportQuery.page = page;
  void loadReports();
}

function changeReportPageSize(pageSize: number): void {
  reportQuery.pageSize = pageSize;
  reportQuery.page = 1;
  void loadReports();
}

function openComment(itemOrId: CommentItem | number): void {
  selectedCommentId.value = typeof itemOrId === 'number' ? itemOrId : itemOrId.id;
  reportDrawerOpen.value = false;
  commentDrawerOpen.value = true;
}

function openReport(item: ReportItem): void {
  selectedReport.value = item;
  commentDrawerOpen.value = false;
  reportDrawerOpen.value = true;
}

async function changeCommentStatus(item: CommentItem, status: CommentStatus): Promise<void> {
  if (rowUpdatingId.value) return;
  rowUpdatingId.value = item.id;
  try {
    await updateCommentStatus(item.id, status);
    ElMessage.success(status === 'deleted' ? '评论已删除' : '评论已恢复展示');
    if (commentItems.value.length === 1 && commentQuery.page > 1) commentQuery.page -= 1;
    await Promise.all([loadComments(), refreshReportCounts()]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '评论状态更新失败'));
  } finally {
    rowUpdatingId.value = null;
  }
}

async function handleDrawerCommentChanged(): Promise<void> {
  await Promise.all([loadComments(), refreshReportCounts()]);
}

async function changeReportStatus(status: ReportStatus): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    await updateReportStatus(selectedReport.value.id, status);
    const message = {
      open: '举报已重新打开并回到待处理队列',
      resolved: '举报已处理，目标内容保持不变',
      ignored: '举报已忽略，目标内容保持不变',
    }[status];
    ElMessage.success(message);
    reportDrawerOpen.value = false;
    if (reportItems.value.length === 1 && reportQuery.page > 1) reportQuery.page -= 1;
    await loadReports();
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报状态更新失败'));
  } finally {
    reportProcessing.value = false;
  }
}

async function deleteReportedTarget(): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    const target = reportTargetLabel(selectedReport.value.targetType);
    const result = await resolveReportAndDeleteTarget(selectedReport.value.id);
    ElMessage.success(result.deleted > 0 ? `${target}已处置，举报已完成` : '目标已不存在，举报已完成');
    reportDrawerOpen.value = false;
    await Promise.all([loadReports(), loadComments()]);
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报目标处置失败'));
  } finally {
    reportProcessing.value = false;
  }
}

async function refreshReportCounts(): Promise<void> {
  try {
    const data = await listReports({ page: 1, pageSize: 1, status: reportQuery.status });
    reportStatusCounts.value = data.statusCounts;
    reportTargetCounts.value = data.targetCounts;
  } catch {
    // The report screen will show a visible error if its own refresh fails.
  }
}

function commentScene(item: CommentItem): string {
  const segments = [`${contentTargetLabel(item.targetType)} ${item.targetId}`];
  if (item.chapterId) segments.push(`章节 ${item.chapterId}`);
  if (item.episodeId) segments.push(`剧集 ${item.episodeId}`);
  return segments.join(' / ');
}

function targetCountLabel(item: CountItem, kind: 'comment' | 'report'): string {
  return kind === 'comment' ? contentTargetLabel(item.key) : reportTargetLabel(item.key);
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="page-stack moderation-page">
    <section class="moderation-hero">
      <div class="hero-copy">
        <span class="eyebrow">TRUST &amp; SAFETY WORKBENCH</span>
        <h2>让审核员先看清上下文，再做处置</h2>
        <p>评论、回复与举报目标统一呈现；所有状态使用明确选项，高风险动作说明影响并二次确认。</p>
      </div>
      <div class="hero-queue" :class="{ 'has-work': openReportCount > 0 }">
        <span class="queue-icon"><ElIcon><Flag /></ElIcon></span>
        <div>
          <strong>{{ openReportCount }}</strong>
          <span>条待处理举报</span>
        </div>
      </div>
    </section>

    <section class="mode-switcher">
      <button
        type="button"
        :class="{ active: activeMode === 'comments' }"
        @click="switchMode('comments')"
      >
        <span class="mode-icon"><ElIcon><Tickets /></ElIcon></span>
        <span><strong>评论审核</strong><small>浏览内容、回复与完整对话</small></span>
        <b>{{ allCommentCount }}</b>
      </button>
      <button
        type="button"
        :class="{ active: activeMode === 'reports' }"
        @click="switchMode('reports')"
      >
        <span class="mode-icon"><ElIcon><Flag /></ElIcon></span>
        <span><strong>举报中心</strong><small>核对目标并记录处置结果</small></span>
        <b>{{ openReportCount }}</b>
      </button>
    </section>

    <template v-if="activeMode === 'comments'">
      <section class="summary-strip" aria-label="评论状态概览">
        <button type="button" :class="{ active: commentQuery.status === '' }" @click="filterComments('')">
          <span>全部评论</span><strong>{{ allCommentCount }}</strong><small>完整内容池</small>
        </button>
        <button type="button" :class="{ active: commentQuery.status === 'visible' }" @click="filterComments('visible')">
          <span>正常展示</span><strong>{{ commentStatusCounts.visible || 0 }}</strong><small>用户当前可见</small>
        </button>
        <button type="button" :class="{ active: commentQuery.status === 'deleted' }" @click="filterComments('deleted')">
          <span>已删除</span><strong>{{ commentStatusCounts.deleted || 0 }}</strong><small>可核查与恢复</small>
        </button>
        <div class="summary-breakdown">
          <span>内容类型分布</span>
          <div>
            <small v-for="item in commentTargetCounts.slice(0, 4)" :key="item.key">
              {{ targetCountLabel(item, 'comment') }} <b>{{ item.count }}</b>
            </small>
            <small v-if="commentTargetCounts.length === 0">暂无数据</small>
          </div>
        </div>
      </section>

      <section class="workbench-card">
        <header class="workbench-toolbar">
          <div class="toolbar-copy">
            <h3>评论内容池</h3>
            <p>当前筛选共 {{ commentTotal }} 条，点击“查看上下文”可读取上级评论、回复和关联举报。</p>
          </div>
          <div class="filter-row">
            <ElInput
              v-model="commentQuery.q"
              clearable
              class="search-input"
              placeholder="搜索评论、用户或内容 ID"
              :prefix-icon="Search"
              @keyup.enter="searchComments"
              @clear="searchComments"
            />
            <ElSelect v-model="commentQuery.status" class="filter-select" placeholder="展示状态" @change="searchComments">
              <ElOption label="全部状态" value="" />
              <ElOption label="正常展示" value="visible" />
              <ElOption label="已删除" value="deleted" />
            </ElSelect>
            <ElSelect v-model="commentQuery.targetType" class="filter-select" placeholder="内容类型" @change="searchComments">
              <ElOption label="全部类型" value="" />
              <ElOption
                v-for="item in commentTargetCounts"
                :key="item.key"
                :label="`${targetCountLabel(item, 'comment')} (${item.count})`"
                :value="item.key"
              />
            </ElSelect>
            <ElButton type="primary" :icon="Search" @click="searchComments">查询</ElButton>
            <ElButton :icon="Refresh" :loading="commentLoading" @click="loadComments">刷新</ElButton>
          </div>
        </header>

        <div v-loading="commentLoading" class="moderation-list comment-list">
          <div class="list-head comment-grid" aria-hidden="true">
            <span>评论内容</span><span>发布者</span><span>内容场景</span><span>互动</span><span>状态 / 时间</span><span>操作</span>
          </div>
          <article v-for="item in commentItems" :key="item.id" class="list-row comment-grid">
            <div class="content-cell">
              <span class="row-kicker">评论 #{{ item.id }}<template v-if="item.parentId"> · 回复 #{{ item.parentId }}</template></span>
              <strong>{{ item.content }}</strong>
            </div>
            <div class="user-cell">
              <span class="mini-avatar">{{ item.user.nickname?.slice(0, 1) || item.user.id }}</span>
              <span><strong>{{ item.user.nickname || `用户 #${item.user.id}` }}</strong><small>UID {{ item.user.id }}</small></span>
            </div>
            <div class="scene-cell">
              <strong>{{ contentTargetLabel(item.targetType) }}</strong>
              <small>{{ commentScene(item) }}</small>
            </div>
            <div class="metrics-cell">
              <span>赞 {{ item.likeCount }}</span>
              <span>回复 {{ item.replyCount }}</span>
              <span v-if="item.rating">评分 {{ item.rating }}</span>
            </div>
            <div class="status-cell">
              <ElTag size="small" :type="item.status === 'visible' ? 'success' : 'info'">
                {{ commentStatusLabel(item.status) }}
              </ElTag>
              <small>{{ formatDateTime(item.createdAt) }}</small>
            </div>
            <div class="row-actions">
              <ElButton size="small" type="primary" plain :icon="View" @click="openComment(item)">查看上下文</ElButton>
              <ElPopconfirm
                v-if="item.status === 'visible'"
                width="260"
                title="删除后前台不再展示，确定继续？"
                confirm-button-text="确认删除"
                cancel-button-text="取消"
                @confirm="changeCommentStatus(item, 'deleted')"
              >
                <template #reference>
                  <ElButton size="small" type="danger" text :loading="rowUpdatingId === item.id">删除</ElButton>
                </template>
              </ElPopconfirm>
              <ElButton
                v-else
                size="small"
                type="primary"
                text
                :loading="rowUpdatingId === item.id"
                @click="changeCommentStatus(item, 'visible')"
              >恢复</ElButton>
            </div>
          </article>
          <div v-if="!commentLoading && commentItems.length === 0" class="friendly-empty list-empty">
            <ElIcon><ChatLineRound /></ElIcon><strong>没有符合条件的评论</strong><span>调整关键词或筛选条件后再试</span>
          </div>
        </div>

        <footer v-if="commentTotal > 0" class="pagination-row">
          <ElPagination
            background
            :current-page="commentQuery.page"
            :page-size="commentQuery.pageSize"
            :page-sizes="[10, 20, 50]"
            :pager-count="5"
            layout="total, sizes, prev, pager, next"
            :total="commentTotal"
            @current-change="changeCommentPage"
            @size-change="changeCommentPageSize"
          />
        </footer>
      </section>
    </template>

    <template v-else>
      <section class="summary-strip report-summary" aria-label="举报状态概览">
        <button type="button" :class="{ active: reportQuery.status === 'open' }" @click="filterReports('open')">
          <span>待处理</span><strong>{{ reportStatusCounts.open || 0 }}</strong><small>优先核查</small>
        </button>
        <button type="button" :class="{ active: reportQuery.status === 'resolved' }" @click="filterReports('resolved')">
          <span>已处理</span><strong>{{ reportStatusCounts.resolved || 0 }}</strong><small>保留处置记录</small>
        </button>
        <button type="button" :class="{ active: reportQuery.status === 'ignored' }" @click="filterReports('ignored')">
          <span>已忽略</span><strong>{{ reportStatusCounts.ignored || 0 }}</strong><small>内容判定合规</small>
        </button>
        <button type="button" :class="{ active: reportQuery.status === '' }" @click="filterReports('')">
          <span>全部举报</span>
          <strong>{{ Object.values(reportStatusCounts).reduce((sum, count) => sum + Number(count || 0), 0) }}</strong>
          <small>查看完整历史</small>
        </button>
      </section>

      <section class="workbench-card">
        <header class="workbench-toolbar">
          <div class="toolbar-copy">
            <h3>举报处置队列</h3>
            <p>当前筛选共 {{ reportTotal }} 条；处理、忽略、删除目标是不同决定，系统将分别记录。</p>
          </div>
          <div class="filter-row">
            <ElInput
              v-model="reportQuery.q"
              clearable
              class="search-input"
              placeholder="搜索举报理由、用户或目标 ID"
              :prefix-icon="Search"
              @keyup.enter="searchReports"
              @clear="searchReports"
            />
            <ElSelect v-model="reportQuery.status" class="filter-select" placeholder="处置状态" @change="searchReports">
              <ElOption label="全部状态" value="" />
              <ElOption label="待处理" value="open" />
              <ElOption label="已处理" value="resolved" />
              <ElOption label="已忽略" value="ignored" />
            </ElSelect>
            <ElSelect v-model="reportQuery.targetType" class="filter-select" placeholder="举报目标" @change="searchReports">
              <ElOption label="全部目标" value="" />
              <ElOption
                v-for="item in reportTargetCounts"
                :key="item.key"
                :label="`${targetCountLabel(item, 'report')} (${item.count})`"
                :value="item.key"
              />
            </ElSelect>
            <ElButton type="primary" :icon="Search" @click="searchReports">查询</ElButton>
            <ElButton :icon="Refresh" :loading="reportLoading" @click="loadReports">刷新</ElButton>
          </div>
        </header>

        <div v-loading="reportLoading" class="moderation-list report-list">
          <div class="list-head report-grid" aria-hidden="true">
            <span>举报理由</span><span>目标预览</span><span>举报人</span><span>状态 / 时间</span><span>操作</span>
          </div>
          <article v-for="item in reportItems" :key="item.id" class="list-row report-grid" :class="{ 'is-open': item.status === 'open' }">
            <div class="content-cell report-reason">
              <span class="row-kicker"><ElIcon><Warning /></ElIcon> 举报 #{{ item.id }} · {{ reportTargetLabel(item.targetType) }}</span>
              <strong>{{ item.reason }}</strong>
            </div>
            <div class="preview-cell" :class="{ missing: !item.preview }">
              <span>{{ reportPreviewText(item) }}</span>
              <small>{{ reportTargetLabel(item.targetType) }} #{{ item.targetId }}</small>
            </div>
            <div class="reporter-cell">
              <strong>{{ item.reporter?.nickname || '匿名用户' }}</strong>
              <small>{{ item.reporter ? `UID ${item.reporter.id}` : '账号已注销或匿名' }}</small>
            </div>
            <div class="status-cell">
              <ElTag size="small" :type="reportStatusTone(item.status)">{{ reportStatusLabel(item.status) }}</ElTag>
              <small>{{ formatDateTime(item.createdAt) }}</small>
              <small v-if="item.handler">处理人 {{ item.handler.nickname }}</small>
            </div>
            <div class="row-actions">
              <ElButton :type="item.status === 'open' ? 'primary' : 'default'" size="small" :icon="View" @click="openReport(item)">
                {{ item.status === 'open' ? '查看并处理' : '查看记录' }}
              </ElButton>
            </div>
          </article>
          <div v-if="!reportLoading && reportItems.length === 0" class="friendly-empty list-empty">
            <ElIcon><CircleCheck /></ElIcon><strong>当前队列已经清空</strong><span>没有符合筛选条件的举报</span>
          </div>
        </div>

        <footer v-if="reportTotal > 0" class="pagination-row">
          <ElPagination
            background
            :current-page="reportQuery.page"
            :page-size="reportQuery.pageSize"
            :page-sizes="[10, 20, 50]"
            :pager-count="5"
            layout="total, sizes, prev, pager, next"
            :total="reportTotal"
            @current-change="changeReportPage"
            @size-change="changeReportPageSize"
          />
        </footer>
      </section>
    </template>

    <CommentContextDrawer
      v-model="commentDrawerOpen"
      :comment-id="selectedCommentId"
      @status-changed="handleDrawerCommentChanged"
      @open-comment="openComment"
      @open-report="openReport"
    />
    <ReportDetailDrawer
      v-model="reportDrawerOpen"
      :report="selectedReport"
      :processing="reportProcessing"
      @change-status="changeReportStatus"
      @delete-target="deleteReportedTarget"
      @open-comment="openComment"
    />
  </div>
</template>

<style scoped>
.moderation-page {
  --comment-grid: minmax(240px, 1.6fr) minmax(140px, 0.75fr) minmax(170px, 1fr) minmax(100px, 0.55fr) minmax(130px, 0.7fr) 178px;
  --report-grid: minmax(220px, 1.1fr) minmax(260px, 1.45fr) minmax(130px, 0.65fr) minmax(140px, 0.7fr) 126px;
}

.moderation-hero {
  min-height: 178px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 28px;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  padding: 30px 34px;
  background:
    radial-gradient(circle at 86% 10%, rgb(255 205 222 / 70%), transparent 34%),
    linear-gradient(145deg, #fff, #fffbfc);
  box-shadow: var(--shadow-sm);
}

.hero-copy h2,
.hero-copy p {
  margin: 0;
}

.hero-copy h2 {
  margin-top: 8px;
  color: var(--ink-900);
  font-size: clamp(23px, 2.2vw, 32px);
  letter-spacing: -0.03em;
}

.hero-copy p {
  max-width: 780px;
  margin-top: 9px;
  color: var(--ink-500);
  font-size: 13px;
  line-height: 1.7;
}

.hero-queue {
  min-width: 190px;
  display: flex;
  align-items: center;
  gap: 13px;
  border: 1px solid var(--line);
  border-radius: 17px;
  padding: 16px;
  background: rgb(255 255 255 / 82%);
}

.hero-queue.has-work {
  border-color: #f2d1b9;
  background: #fff9f3;
}

.queue-icon {
  width: 42px;
  height: 42px;
  display: grid;
  place-items: center;
  border-radius: 13px;
  color: #a65b23;
  background: #fff0e2;
  font-size: 19px;
}

.hero-queue > div {
  display: grid;
}

.hero-queue strong {
  color: var(--ink-900);
  font-size: 24px;
  line-height: 1;
}

.hero-queue span:last-child {
  margin-top: 5px;
  color: var(--ink-500);
  font-size: 10px;
}

.mode-switcher {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}

.mode-switcher > button {
  min-width: 0;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 12px;
  border: 1px solid var(--line);
  border-radius: 16px;
  padding: 15px 17px;
  text-align: left;
  color: inherit;
  background: white;
  box-shadow: var(--shadow-sm);
}

.mode-switcher > button:hover,
.mode-switcher > button.active {
  border-color: var(--sakura-200);
  background: linear-gradient(145deg, #fff, var(--sakura-50));
}

.mode-switcher > button.active {
  box-shadow: 0 10px 28px rgb(220 84 127 / 9%);
}

.mode-icon {
  width: 40px;
  height: 40px;
  display: grid;
  place-items: center;
  border-radius: 12px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 18px;
}

.mode-switcher button > span:nth-child(2) {
  min-width: 0;
  display: grid;
}

.mode-switcher strong {
  color: var(--ink-900);
  font-size: 13px;
}

.mode-switcher small {
  margin-top: 4px;
  overflow: hidden;
  color: var(--ink-500);
  font-size: 10px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.mode-switcher b {
  min-width: 30px;
  color: var(--sakura-600);
  font-size: 18px;
  text-align: center;
}

.summary-strip {
  display: grid;
  grid-template-columns: repeat(3, minmax(130px, 0.65fr)) minmax(260px, 1.5fr);
  gap: 12px;
}

.summary-strip > button,
.summary-breakdown {
  min-width: 0;
  min-height: 112px;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  border: 1px solid var(--line);
  border-radius: 15px;
  padding: 14px 16px;
  text-align: left;
  color: inherit;
  background: white;
  box-shadow: var(--shadow-sm);
}

.summary-strip > button:hover,
.summary-strip > button.active {
  border-color: var(--sakura-200);
}

.summary-strip > button.active {
  background: linear-gradient(145deg, white, var(--sakura-50));
}

.summary-strip span {
  color: var(--ink-500);
  font-size: 11px;
}

.summary-strip strong {
  margin-top: auto;
  color: var(--ink-900);
  font-size: 25px;
  line-height: 1;
}

.summary-strip > button small {
  margin-top: 7px;
  color: var(--ink-300);
  font-size: 9px;
}

.summary-breakdown > div {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
  margin-top: auto;
}

.summary-breakdown small {
  border-radius: 999px;
  padding: 6px 9px;
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 10px;
}

.summary-breakdown b {
  margin-left: 3px;
  color: var(--ink-900);
}

.report-summary {
  grid-template-columns: repeat(4, minmax(130px, 1fr));
}

.workbench-card {
  min-width: 0;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: var(--radius-md);
  background: white;
  box-shadow: var(--shadow-sm);
}

.workbench-toolbar {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 20px;
  padding: 18px 20px;
  border-bottom: 1px solid var(--line);
}

.toolbar-copy {
  min-width: 240px;
}

.toolbar-copy h3,
.toolbar-copy p {
  margin: 0;
}

.toolbar-copy h3 {
  color: var(--ink-900);
  font-size: 15px;
}

.toolbar-copy p {
  margin-top: 5px;
  color: var(--ink-500);
  font-size: 10px;
  line-height: 1.5;
}

.filter-row {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
}

.search-input {
  width: min(290px, 28vw);
}

.filter-select {
  width: 142px;
}

.moderation-list {
  min-height: 260px;
}

.comment-grid {
  display: grid;
  grid-template-columns: var(--comment-grid);
  gap: 14px;
}

.report-grid {
  display: grid;
  grid-template-columns: var(--report-grid);
  gap: 14px;
}

.list-head {
  align-items: center;
  border-bottom: 1px solid var(--line);
  padding: 10px 20px;
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 10px;
  font-weight: 700;
}

.list-row {
  min-width: 0;
  align-items: center;
  border-bottom: 1px solid #f1eef2;
  padding: 14px 20px;
  transition: background 120ms ease;
}

.list-row:hover {
  background: #fffafb;
}

.list-row.is-open {
  box-shadow: inset 3px 0 #edb16f;
}

.content-cell,
.scene-cell,
.status-cell,
.reporter-cell,
.preview-cell {
  min-width: 0;
  display: grid;
}

.row-kicker {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-bottom: 5px;
  color: var(--sakura-500);
  font-size: 9px;
  font-weight: 700;
}

.content-cell > strong {
  display: -webkit-box;
  overflow: hidden;
  color: var(--ink-900);
  font-size: 12px;
  font-weight: 600;
  line-height: 1.55;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  word-break: break-word;
}

.user-cell {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 8px;
}

.mini-avatar {
  width: 32px;
  height: 32px;
  flex: 0 0 32px;
  display: grid;
  place-items: center;
  border-radius: 10px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 11px;
  font-weight: 800;
}

.user-cell > span:last-child,
.scene-cell,
.status-cell,
.reporter-cell {
  min-width: 0;
  display: grid;
  justify-items: start;
}

.user-cell strong,
.scene-cell strong,
.reporter-cell strong {
  max-width: 100%;
  overflow: hidden;
  color: var(--ink-900);
  font-size: 11px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.user-cell small,
.scene-cell small,
.status-cell small,
.reporter-cell small,
.preview-cell small {
  max-width: 100%;
  margin-top: 4px;
  overflow: hidden;
  color: var(--ink-500);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.metrics-cell {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
}

.metrics-cell span {
  border-radius: 999px;
  padding: 4px 6px;
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 9px;
}

.row-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 4px;
}

.row-actions .el-button + .el-button {
  margin-left: 0;
}

.preview-cell {
  border-left: 2px solid var(--sakura-100);
  padding-left: 10px;
}

.preview-cell > span {
  display: -webkit-box;
  overflow: hidden;
  color: var(--ink-700);
  font-size: 11px;
  line-height: 1.5;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  word-break: break-word;
}

.preview-cell.missing {
  border-left-color: var(--line);
}

.preview-cell.missing > span {
  color: var(--ink-300);
}

.report-reason .row-kicker {
  color: #a65b23;
}

.pagination-row {
  display: flex;
  justify-content: flex-end;
  padding: 15px 20px;
  border-top: 1px solid var(--line);
}

.list-empty {
  min-height: 260px;
}

@media (max-width: 1420px) {
  .workbench-toolbar {
    align-items: stretch;
    flex-direction: column;
  }

  .filter-row {
    justify-content: flex-start;
  }

  .search-input {
    width: min(340px, 36vw);
  }

  .list-head {
    display: none;
  }

  .list-row.comment-grid,
  .list-row.report-grid {
    grid-template-columns: minmax(230px, 1.3fr) minmax(150px, 0.7fr) minmax(190px, 0.9fr);
    gap: 12px 18px;
  }

  .comment-grid .metrics-cell,
  .comment-grid .status-cell,
  .comment-grid .row-actions,
  .report-grid .reporter-cell,
  .report-grid .status-cell,
  .report-grid .row-actions {
    border-top: 1px dashed var(--line);
    padding-top: 10px;
  }

  .row-actions {
    justify-content: flex-start;
  }
}

@media (max-width: 900px) {
  .summary-strip,
  .report-summary {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .filter-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(130px, 0.45fr) minmax(130px, 0.45fr) auto auto;
  }

  .search-input,
  .filter-select {
    width: 100%;
  }

  .list-row.comment-grid,
  .list-row.report-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 680px) {
  .moderation-hero {
    min-height: 0;
    align-items: stretch;
    flex-direction: column;
    padding: 23px;
  }

  .hero-queue {
    min-width: 0;
  }

  .mode-switcher {
    grid-template-columns: 1fr;
  }

  .summary-strip,
  .report-summary {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .summary-strip > button,
  .summary-breakdown {
    min-height: 102px;
    padding: 12px;
  }

  .summary-breakdown {
    grid-column: 1 / -1;
  }

  .workbench-toolbar {
    padding: 15px;
  }

  .filter-row {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .search-input {
    grid-column: 1 / -1;
  }

  .filter-row > .el-button {
    width: 100%;
    margin-left: 0;
  }

  .list-row.comment-grid,
  .list-row.report-grid {
    grid-template-columns: 1fr;
    padding: 16px;
  }

  .comment-grid > div:not(:first-child),
  .report-grid > div:not(:first-child) {
    border-top: 1px dashed var(--line);
    padding-top: 10px;
  }

  .metrics-cell,
  .row-actions {
    border-top: 1px dashed var(--line);
    padding-top: 10px;
  }

  .preview-cell {
    border-left: 0;
  }

  .pagination-row {
    justify-content: center;
    overflow-x: auto;
    padding-inline: 10px;
  }

  .pagination-row :deep(.el-pagination__total),
  .pagination-row :deep(.el-pagination__sizes) {
    display: none;
  }
}
</style>
