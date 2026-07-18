<script setup lang="ts">
import {
  Check,
  Delete,
  EditPen,
  Plus,
  Reading,
  Refresh,
  Search,
  UploadFilled,
  View,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import NovelEditorDrawer from '@/components/ai-novels/NovelEditorDrawer.vue';
import NovelReviewDrawer from '@/components/ai-novels/NovelReviewDrawer.vue';
import {
  createNovelDraft,
  deleteNovel,
  listCreatorNovels,
  listReviewChapters,
  listReviewNovels,
} from '@/services/ai-novels';
import { useSessionStore } from '@/stores/session';
import type { AiNovelChapter, AiNovelStatus, AiNovelSummary } from '@/types/ai-novel';
import { formatDateTime } from '@/utils/format';

const session = useSessionStore();
const activeTab = ref('mine');
const creatorLoading = ref(false);
const reviewLoading = ref(false);
const creating = ref(false);
const creatorItems = ref<AiNovelSummary[]>([]);
const creatorTotal = ref(0);
const reviewNovelItems = ref<AiNovelSummary[]>([]);
const reviewChapterItems = ref<AiNovelChapter[]>([]);
const reviewTotal = ref(0);
const pendingNovelCount = ref(0);
const pendingChapterCount = ref(0);
const reviewMode = ref<'novel' | 'chapter'>('novel');
const editorOpen = ref(false);
const editorNovelId = ref<number | null>(null);
const reviewOpen = ref(false);
const reviewTarget = ref<{ kind: 'novel' | 'chapter'; id: number } | null>(null);

const creatorQuery = reactive({
  q: '',
  status: '',
  page: 1,
  pageSize: 10,
});

const reviewQuery = reactive({
  q: '',
  status: 'pending',
  page: 1,
  pageSize: 10,
});

const totalPending = computed(() => pendingNovelCount.value + pendingChapterCount.value);

onMounted(async () => {
  await loadCreatorList();
  if (session.isAdmin) await refreshQueueCounts();
});

async function loadCreatorList(): Promise<void> {
  creatorLoading.value = true;
  try {
    const data = await listCreatorNovels(creatorQuery);
    creatorItems.value = data.items;
    creatorTotal.value = data.total;
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    creatorLoading.value = false;
  }
}

async function loadReviewList(): Promise<void> {
  if (!session.isAdmin) return;
  reviewLoading.value = true;
  try {
    const data = reviewMode.value === 'novel'
      ? await listReviewNovels(reviewQuery)
      : await listReviewChapters(reviewQuery);
    reviewTotal.value = data.total;
    if (reviewMode.value === 'novel') reviewNovelItems.value = data.items as AiNovelSummary[];
    else reviewChapterItems.value = data.items as AiNovelChapter[];
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    reviewLoading.value = false;
  }
}

async function refreshQueueCounts(): Promise<void> {
  if (!session.isAdmin) return;
  try {
    const [novels, chapters] = await Promise.all([
      listReviewNovels({ status: 'pending', page: 1, pageSize: 1 }),
      listReviewChapters({ status: 'pending', page: 1, pageSize: 1 }),
    ]);
    pendingNovelCount.value = novels.total;
    pendingChapterCount.value = chapters.total;
  } catch {
    // The visible queue will surface actionable errors when opened.
  }
}

async function refreshReviewWorkbench(): Promise<void> {
  await Promise.all([loadReviewList(), refreshQueueCounts()]);
}

async function changeMainTab(name: string | number): Promise<void> {
  activeTab.value = String(name);
  if (activeTab.value === 'review') {
    reviewQuery.page = 1;
    await loadReviewList();
  }
}

async function changeReviewMode(mode: 'novel' | 'chapter'): Promise<void> {
  reviewMode.value = mode;
  reviewQuery.page = 1;
  reviewQuery.status = 'pending';
  await loadReviewList();
}

async function createDraft(): Promise<void> {
  creating.value = true;
  try {
    const draft = await createNovelDraft();
    editorNovelId.value = draft.item.numericId;
    editorOpen.value = true;
    await loadCreatorList();
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    creating.value = false;
  }
}

function openEditor(value: unknown): void {
  const item = value as AiNovelSummary;
  editorNovelId.value = item.numericId;
  editorOpen.value = true;
}

function openNovelReview(value: unknown): void {
  const item = value as AiNovelSummary;
  reviewTarget.value = { kind: 'novel', id: item.numericId };
  reviewOpen.value = true;
}

function openChapterReview(value: unknown): void {
  const item = value as AiNovelChapter;
  reviewTarget.value = { kind: 'chapter', id: item.id };
  reviewOpen.value = true;
}

async function removeDraft(value: unknown): Promise<void> {
  const item = value as AiNovelSummary;
  try {
    await deleteNovel(item.numericId);
    ElMessage.success('草稿已删除');
    if (creatorItems.value.length === 1 && creatorQuery.page > 1) creatorQuery.page -= 1;
    await loadCreatorList();
  } catch (error) {
    ElMessage.error(errorMessage(error));
  }
}

async function handleEditorSaved(): Promise<void> {
  await loadCreatorList();
  await refreshQueueCounts();
}

async function handleReviewed(): Promise<void> {
  await Promise.all([loadReviewList(), refreshQueueCounts()]);
}

function searchCreator(): void {
  creatorQuery.page = 1;
  void loadCreatorList();
}

function searchReview(): void {
  reviewQuery.page = 1;
  void loadReviewList();
}

function statusLabel(status: AiNovelStatus): string {
  return {
    draft: '草稿',
    pending: '审核中',
    published: '已发布',
    rejected: '需修改',
  }[status];
}

function statusType(status: AiNovelStatus): 'info' | 'warning' | 'success' | 'danger' {
  return {
    draft: 'info',
    pending: 'warning',
    published: 'success',
    rejected: 'danger',
  }[status] as 'info' | 'warning' | 'success' | 'danger';
}

function editorActionLabel(status: AiNovelStatus): string {
  return {
    draft: '继续编辑',
    pending: '查看提交',
    published: '管理连载',
    rejected: '修改重投',
  }[status];
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '操作失败，请稍后重试';
}
</script>

<template>
  <div class="page-stack ai-novel-page">
    <section class="workflow-banner">
      <div class="workflow-copy">
        <span class="eyebrow">AI NOVEL WORKFLOW</span>
        <h2>从文件导入到发布，每一步都可预览、可修改、可追踪</h2>
        <p>封面直接上传，TXT / Markdown 自动识别编码和章节；审核员能阅读全文，驳回后保留意见并支持重新提交。</p>
      </div>
      <div class="workflow-steps" aria-label="AI 小说工作流">
        <div><b>1</b><span><strong>上传与拆章</strong><small>先预览，不直接发布</small></span></div>
        <i />
        <div><b>2</b><span><strong>保存与提交</strong><small>草稿和版本冲突保护</small></span></div>
        <i />
        <div><b>3</b><span><strong>审核与发布</strong><small>全文审核及历史记录</small></span></div>
      </div>
    </section>

    <section class="novel-workbench">
      <ElTabs :model-value="activeTab" class="workbench-tabs" @tab-change="changeMainTab">
        <ElTabPane name="mine">
          <template #label><span class="tab-label"><ElIcon><EditPen /></ElIcon>我的作品</span></template>

          <div class="toolbar">
            <div class="toolbar-filters">
              <ElInput
                v-model="creatorQuery.q"
                clearable
                placeholder="搜索作品名、笔名或分类"
                :prefix-icon="Search"
                @keyup.enter="searchCreator"
                @clear="searchCreator"
              />
              <ElSelect v-model="creatorQuery.status" placeholder="全部状态" clearable @change="searchCreator">
                <ElOption label="草稿" value="draft" />
                <ElOption label="审核中" value="pending" />
                <ElOption label="已发布" value="published" />
                <ElOption label="需修改" value="rejected" />
              </ElSelect>
              <ElButton :icon="Search" @click="searchCreator">筛选</ElButton>
              <ElButton :icon="Refresh" circle title="刷新" @click="loadCreatorList" />
            </div>
            <ElButton type="primary" :icon="Plus" :loading="creating" @click="createDraft">新建 AI 小说</ElButton>
          </div>

          <ElTable v-loading="creatorLoading" :data="creatorItems" class="novel-table" empty-text="还没有作品，先创建一个草稿吧">
            <ElTableColumn label="作品" min-width="320">
              <template #default="scope">
                <div class="novel-cell">
                  <img v-if="scope.row.coverUrl" :src="scope.row.coverUrl" alt="">
                  <div v-else class="cover-placeholder"><ElIcon><Reading /></ElIcon></div>
                  <div>
                    <strong>{{ scope.row.title }}</strong>
                    <span>{{ scope.row.author }} · {{ scope.row.category }}</span>
                    <p>{{ scope.row.description || '尚未填写作品简介' }}</p>
                  </div>
                </div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="状态" width="112">
              <template #default="scope">
                <ElTag :type="statusType(scope.row.status)" effect="light">{{ statusLabel(scope.row.status) }}</ElTag>
              </template>
            </ElTableColumn>
            <ElTableColumn label="章节" width="126">
              <template #default="scope">
                <div class="chapter-count"><strong>{{ scope.row.chapterCount }}</strong><small>总章节</small></div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="最近更新" width="150">
              <template #default="scope">{{ formatDateTime(scope.row.updatedAt) }}</template>
            </ElTableColumn>
            <ElTableColumn label="操作" width="210" fixed="right">
              <template #default="scope">
                <ElButton type="primary" link :icon="scope.row.status === 'pending' ? View : EditPen" @click="openEditor(scope.row)">
                  {{ editorActionLabel(scope.row.status) }}
                </ElButton>
                <ElPopconfirm
                  v-if="scope.row.status === 'draft' || scope.row.status === 'rejected'"
                  title="删除该草稿及未发布章节？"
                  width="210"
                  confirm-button-text="删除"
                  cancel-button-text="取消"
                  @confirm="removeDraft(scope.row)"
                >
                  <template #reference><ElButton type="danger" link :icon="Delete">删除</ElButton></template>
                </ElPopconfirm>
              </template>
            </ElTableColumn>
          </ElTable>

          <div v-if="creatorTotal > creatorQuery.pageSize" class="pagination-row">
            <ElPagination
              v-model:current-page="creatorQuery.page"
              v-model:page-size="creatorQuery.pageSize"
              background
              layout="total, sizes, prev, pager, next"
              :page-sizes="[10, 20, 50]"
              :total="creatorTotal"
              @change="loadCreatorList"
            />
          </div>
        </ElTabPane>

        <ElTabPane v-if="session.isAdmin" name="review">
          <template #label>
            <span class="tab-label"><ElIcon><Check /></ElIcon>审核工作台<ElBadge v-if="totalPending" :value="totalPending" /></span>
          </template>

          <div class="queue-switcher">
            <button :class="{ active: reviewMode === 'novel' }" type="button" @click="changeReviewMode('novel')">
              <UploadFilled /><span><strong>整书首发审核</strong><small>{{ pendingNovelCount }} 项待处理</small></span>
            </button>
            <button :class="{ active: reviewMode === 'chapter' }" type="button" @click="changeReviewMode('chapter')">
              <Reading /><span><strong>连载章节审核</strong><small>{{ pendingChapterCount }} 项待处理</small></span>
            </button>
          </div>

          <div class="toolbar review-toolbar">
            <div class="toolbar-filters">
              <ElInput
                v-model="reviewQuery.q"
                clearable
                :placeholder="reviewMode === 'novel' ? '搜索作品或投稿人' : '搜索作品、章节或投稿人'"
                :prefix-icon="Search"
                @keyup.enter="searchReview"
                @clear="searchReview"
              />
              <ElSelect v-model="reviewQuery.status" @change="searchReview">
                <ElOption label="待审核" value="pending" />
                <ElOption label="已通过" value="published" />
                <ElOption label="已退回" value="rejected" />
                <ElOption v-if="reviewMode === 'novel'" label="草稿" value="draft" />
              </ElSelect>
              <ElButton :icon="Search" @click="searchReview">筛选</ElButton>
              <ElButton :icon="Refresh" circle title="刷新" @click="refreshReviewWorkbench" />
            </div>
          </div>

          <ElTable
            v-if="reviewMode === 'novel'"
            v-loading="reviewLoading"
            :data="reviewNovelItems"
            class="novel-table"
            empty-text="当前筛选条件下没有整书投稿"
          >
            <ElTableColumn label="投稿作品" min-width="300">
              <template #default="scope">
                <div class="novel-cell compact">
                  <img v-if="scope.row.coverUrl" :src="scope.row.coverUrl" alt="">
                  <div v-else class="cover-placeholder"><ElIcon><Reading /></ElIcon></div>
                  <div><strong>{{ scope.row.title }}</strong><span>{{ scope.row.author }} · {{ scope.row.category }}</span></div>
                </div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="投稿人" min-width="200">
              <template #default="scope"><div class="owner-cell"><strong>{{ scope.row.ownerNickname }}</strong><small>{{ scope.row.ownerEmail }}</small></div></template>
            </ElTableColumn>
            <ElTableColumn label="章节" width="90" prop="chapterCount" />
            <ElTableColumn label="状态" width="100">
              <template #default="scope"><ElTag :type="statusType(scope.row.status)">{{ statusLabel(scope.row.status) }}</ElTag></template>
            </ElTableColumn>
            <ElTableColumn label="提交时间" width="150">
              <template #default="scope">{{ formatDateTime(scope.row.submittedAt || scope.row.updatedAt) }}</template>
            </ElTableColumn>
            <ElTableColumn label="操作" width="120" fixed="right">
              <template #default="scope"><ElButton type="primary" :icon="View" @click="openNovelReview(scope.row)">{{ scope.row.status === 'pending' ? '开始审核' : '查看详情' }}</ElButton></template>
            </ElTableColumn>
          </ElTable>

          <ElTable
            v-else
            v-loading="reviewLoading"
            :data="reviewChapterItems"
            class="novel-table"
            empty-text="当前筛选条件下没有连载章节"
          >
            <ElTableColumn label="作品 / 章节" min-width="310">
              <template #default="scope"><div class="chapter-review-cell"><strong>{{ scope.row.novelTitle }}</strong><span>第 {{ scope.row.index + 1 }} 章 · {{ scope.row.title }}</span></div></template>
            </ElTableColumn>
            <ElTableColumn label="投稿人" min-width="200">
              <template #default="scope"><div class="owner-cell"><strong>{{ scope.row.ownerNickname }}</strong><small>{{ scope.row.ownerEmail }}</small></div></template>
            </ElTableColumn>
            <ElTableColumn label="状态" width="100">
              <template #default="scope"><ElTag :type="statusType(scope.row.status)">{{ statusLabel(scope.row.status) }}</ElTag></template>
            </ElTableColumn>
            <ElTableColumn label="提交时间" width="150">
              <template #default="scope">{{ formatDateTime(scope.row.submittedAt || scope.row.updatedAt) }}</template>
            </ElTableColumn>
            <ElTableColumn label="操作" width="120" fixed="right">
              <template #default="scope"><ElButton type="primary" :icon="View" @click="openChapterReview(scope.row)">{{ scope.row.status === 'pending' ? '开始审核' : '查看详情' }}</ElButton></template>
            </ElTableColumn>
          </ElTable>

          <div v-if="reviewTotal > reviewQuery.pageSize" class="pagination-row">
            <ElPagination
              v-model:current-page="reviewQuery.page"
              v-model:page-size="reviewQuery.pageSize"
              background
              layout="total, sizes, prev, pager, next"
              :page-sizes="[10, 20, 50]"
              :total="reviewTotal"
              @change="loadReviewList"
            />
          </div>
        </ElTabPane>
      </ElTabs>
    </section>

    <NovelEditorDrawer
      v-model="editorOpen"
      :novel-id="editorNovelId"
      @saved="handleEditorSaved"
    />
    <NovelReviewDrawer
      v-if="session.isAdmin"
      v-model="reviewOpen"
      :target="reviewTarget"
      @reviewed="handleReviewed"
    />
  </div>
</template>

<style scoped>
.ai-novel-page {
  gap: 18px;
}

.workflow-banner {
  position: relative;
  overflow: hidden;
  display: grid;
  grid-template-columns: minmax(300px, 0.9fr) minmax(520px, 1.1fr);
  align-items: center;
  gap: 34px;
  min-height: 174px;
  padding: 28px 32px;
  border: 1px solid #f1dbe3;
  border-radius: 22px;
  background:
    radial-gradient(circle at 90% 0%, rgb(255 203 217 / 70%), transparent 34%),
    linear-gradient(135deg, #fff, #fff7f9);
  box-shadow: var(--shadow-sm);
}

.workflow-banner::after {
  position: absolute;
  right: -55px;
  bottom: -85px;
  width: 220px;
  height: 220px;
  border: 38px solid rgb(239 119 155 / 8%);
  border-radius: 50%;
  content: '';
}

.workflow-copy h2,
.workflow-copy p {
  margin: 0;
}

.workflow-copy h2 {
  margin-top: 7px;
  font-size: clamp(20px, 2vw, 28px);
  line-height: 1.35;
}

.workflow-copy p {
  max-width: 620px;
  margin-top: 10px;
  color: var(--ink-500);
  font-size: 13px;
  line-height: 1.7;
}

.workflow-steps {
  position: relative;
  z-index: 1;
  display: grid;
  grid-template-columns: 1fr 28px 1fr 28px 1fr;
  align-items: center;
}

.workflow-steps > div {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 10px;
}

.workflow-steps b {
  width: 36px;
  height: 36px;
  flex: 0 0 36px;
  display: grid;
  place-items: center;
  border-radius: 12px;
  color: var(--sakura-600);
  background: white;
  box-shadow: 0 8px 20px rgb(220 84 127 / 13%);
}

.workflow-steps span {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.workflow-steps strong {
  font-size: 13px;
}

.workflow-steps small {
  overflow: hidden;
  color: var(--ink-500);
  font-size: 10px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.workflow-steps i {
  height: 1px;
  margin: 0 7px;
  background: #e9b7c7;
}

.novel-workbench {
  min-width: 0;
  padding: 0 22px 22px;
  border: 1px solid var(--line);
  border-radius: 20px;
  background: var(--surface);
  box-shadow: var(--shadow-sm);
}

.workbench-tabs :deep(.el-tabs__header) {
  margin-bottom: 18px;
}

.workbench-tabs :deep(.el-tabs__item) {
  height: 58px;
  padding-inline: 20px;
}

.tab-label {
  display: inline-flex;
  align-items: center;
  gap: 7px;
}

.tab-label :deep(.el-badge__content) {
  top: 3px;
  right: 3px;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 16px;
}

.toolbar-filters {
  min-width: 0;
  display: flex;
  align-items: center;
  gap: 10px;
}

.toolbar-filters > .el-input {
  width: min(340px, 34vw);
}

.toolbar-filters > .el-select {
  width: 150px;
}

.novel-table {
  width: 100%;
  border: 1px solid var(--line);
  border-radius: 14px;
}

.novel-cell {
  min-width: 0;
  display: grid;
  grid-template-columns: 58px minmax(0, 1fr);
  align-items: center;
  gap: 12px;
  padding: 4px 0;
}

.novel-cell.compact {
  grid-template-columns: 46px minmax(0, 1fr);
}

.novel-cell img,
.cover-placeholder {
  width: 58px;
  aspect-ratio: 3 / 4;
  border-radius: 8px;
  object-fit: cover;
  background: var(--sakura-50);
}

.compact img,
.compact .cover-placeholder {
  width: 46px;
}

.cover-placeholder {
  display: grid;
  place-items: center;
  color: var(--sakura-400);
  font-size: 20px;
}

.novel-cell > div:last-child,
.owner-cell,
.chapter-review-cell,
.chapter-count {
  min-width: 0;
  display: grid;
}

.novel-cell strong,
.owner-cell strong,
.chapter-review-cell strong {
  overflow: hidden;
  color: var(--ink-900);
  text-overflow: ellipsis;
  white-space: nowrap;
}

.novel-cell span,
.owner-cell small,
.chapter-review-cell span {
  margin-top: 3px;
  overflow: hidden;
  color: var(--ink-500);
  font-size: 12px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.novel-cell p {
  display: -webkit-box;
  overflow: hidden;
  margin: 5px 0 0;
  color: var(--ink-500);
  font-size: 11px;
  line-height: 1.45;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
}

.chapter-count strong {
  font-size: 17px;
}

.chapter-count small {
  color: var(--ink-500);
  font-size: 10px;
}

.pagination-row {
  display: flex;
  justify-content: flex-end;
  margin-top: 18px;
}

.queue-switcher {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px;
  margin-bottom: 16px;
}

.queue-switcher button {
  display: flex;
  align-items: center;
  gap: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 14px 16px;
  color: var(--ink-500);
  background: var(--surface-muted);
  text-align: left;
}

.queue-switcher button > svg {
  width: 24px;
  color: var(--ink-300);
}

.queue-switcher button > span {
  display: grid;
  gap: 3px;
}

.queue-switcher button small {
  font-size: 11px;
}

.queue-switcher button.active {
  border-color: #efb1c4;
  color: var(--sakura-600);
  background: var(--sakura-50);
  box-shadow: inset 0 0 0 1px rgb(220 84 127 / 7%);
}

.queue-switcher button.active > svg {
  color: var(--sakura-500);
}

.review-toolbar {
  justify-content: flex-start;
}

@media (max-width: 1180px) {
  .workflow-banner {
    grid-template-columns: 1fr;
  }
}

@media (max-width: 760px) {
  .workflow-banner {
    padding: 22px;
  }

  .workflow-steps {
    grid-template-columns: 1fr;
    gap: 9px;
  }

  .workflow-steps i {
    width: 1px;
    height: 13px;
    margin-left: 18px;
  }

  .novel-workbench {
    padding-inline: 12px;
  }

  .toolbar,
  .toolbar-filters {
    align-items: stretch;
    flex-direction: column;
  }

  .toolbar-filters > .el-input,
  .toolbar-filters > .el-select,
  .toolbar > .el-button {
    width: 100%;
  }

  .queue-switcher {
    grid-template-columns: 1fr;
  }

  .pagination-row {
    overflow: auto;
    justify-content: flex-start;
  }
}
</style>
