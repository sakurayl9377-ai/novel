<script setup lang="ts">
import {
  Check,
  CloseBold,
  Delete,
  DocumentChecked,
  EditPen,
  Plus,
  Reading,
  Refresh,
  Search,
  View,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import NovelEditorDrawer from '@/components/ai-novels/NovelEditorDrawer.vue';
import NovelReviewDrawer from '@/components/ai-novels/NovelReviewDrawer.vue';
import {
  batchReviewNovels,
  createNovelDraft,
  deleteNovel,
  getReviewQueue,
  listCreatorNovels,
} from '@/services/ai-novels';
import { useSessionStore } from '@/stores/session';
import type {
  AiNovelChapter,
  AiNovelReviewAuthor,
  AiNovelReviewBook,
  AiNovelReviewTarget,
  AiNovelStatus,
  AiNovelSummary,
} from '@/types/ai-novel';
import { formatDateTime } from '@/utils/format';

const session = useSessionStore();
const activeTab = ref('mine');
const creatorLoading = ref(false);
const reviewLoading = ref(false);
const creating = ref(false);
const batchReviewing = ref(false);
const creatorItems = ref<AiNovelSummary[]>([]);
const creatorTotal = ref(0);
const reviewAuthors = ref<AiNovelReviewAuthor[]>([]);
const reviewTotal = ref(0);
const pendingNovelCount = ref(0);
const pendingMetadataCount = ref(0);
const pendingChapterCount = ref(0);
const expandedAuthors = ref<string[]>([]);
const expandedBooks = ref<string[]>([]);
const selectedReviewTargets = ref<AiNovelReviewTarget[]>([]);
const batchRejectOpen = ref(false);
const batchReviewNote = ref('');
const editorOpen = ref(false);
const editorNovelId = ref<number | null>(null);
const reviewOpen = ref(false);
const reviewTarget = ref<{ kind: 'novel' | 'metadata' | 'chapter'; id: number } | null>(null);

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

const totalPending = computed(() =>
  pendingNovelCount.value + pendingMetadataCount.value + pendingChapterCount.value,
);
const selectedTargetKeys = computed(() => new Set(selectedReviewTargets.value.map(reviewTargetKey)));
const selectedTargetCount = computed(() => selectedReviewTargets.value.length);
const canBatchReview = computed(() => reviewQuery.status === 'pending' && selectedTargetCount.value > 0);

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

async function loadReviewQueue(): Promise<void> {
  if (!session.isAdmin) return;
  reviewLoading.value = true;
  try {
    const data = await getReviewQueue(reviewQuery);
    reviewAuthors.value = data.items;
    reviewTotal.value = data.total;
    pendingNovelCount.value = data.summary.pendingNovelCount;
    pendingMetadataCount.value = data.summary.pendingMetadataCount;
    pendingChapterCount.value = data.summary.pendingChapterCount;
    selectedReviewTargets.value = [];
    const authorKeys = new Set(data.items.map(authorKey));
    const bookKeys = new Set(data.items.flatMap((author) => author.novels.map(bookKey)));
    expandedAuthors.value = expandedAuthors.value.filter((key) => authorKeys.has(key));
    expandedBooks.value = expandedBooks.value.filter((key) => bookKeys.has(key));
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    reviewLoading.value = false;
  }
}

async function refreshQueueCounts(): Promise<void> {
  if (!session.isAdmin) return;
  try {
    const data = await getReviewQueue({ status: 'pending', page: 1, pageSize: 1 });
    pendingNovelCount.value = data.summary.pendingNovelCount;
    pendingMetadataCount.value = data.summary.pendingMetadataCount;
    pendingChapterCount.value = data.summary.pendingChapterCount;
  } catch {
    // The visible queue will surface actionable errors when opened.
  }
}

async function refreshReviewWorkbench(): Promise<void> {
  await loadReviewQueue();
}

async function changeMainTab(name: string | number): Promise<void> {
  activeTab.value = String(name);
  if (activeTab.value === 'review') {
    reviewQuery.page = 1;
    await loadReviewQueue();
  }
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

function openMetadataReview(book: AiNovelReviewBook): void {
  if (!book.metadataRevision) return;
  reviewTarget.value = { kind: 'metadata', id: book.metadataRevision.id };
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
  if (activeTab.value === 'review') await loadReviewQueue();
  else await refreshQueueCounts();
}

function searchCreator(): void {
  creatorQuery.page = 1;
  void loadCreatorList();
}

function searchReview(): void {
  reviewQuery.page = 1;
  void loadReviewQueue();
}

function authorKey(author: AiNovelReviewAuthor): string {
  return `author-${author.ownerId}`;
}

function bookKey(book: AiNovelReviewBook): string {
  return `book-${book.numericId}`;
}

function reviewTargetKey(target: AiNovelReviewTarget): string {
  return `${target.kind}-${target.id}`;
}

function novelReviewTarget(book: AiNovelReviewBook): AiNovelReviewTarget[] {
  return book.status === 'pending'
    ? [{ kind: 'novel', id: book.numericId, expectedRevision: book.revision }]
    : [];
}

function metadataReviewTargets(book: AiNovelReviewBook): AiNovelReviewTarget[] {
  const metadata = book.metadataRevision;
  return metadata?.status === 'pending'
    ? [{ kind: 'metadata', id: metadata.id, expectedRevision: metadata.revision }]
    : [];
}

function chapterReviewTargets(book: AiNovelReviewBook): AiNovelReviewTarget[] {
  if (book.status !== 'published') return [];
  return book.chapters
    .filter((chapter) => chapter.status === 'pending')
    .map((chapter) => ({ kind: 'chapter' as const, id: chapter.id, expectedRevision: chapter.revision }));
}

function reviewTargetsForBook(book: AiNovelReviewBook): AiNovelReviewTarget[] {
  return [
    ...novelReviewTarget(book),
    ...metadataReviewTargets(book),
    ...chapterReviewTargets(book),
  ];
}

function reviewTargetsForAuthor(author: AiNovelReviewAuthor): AiNovelReviewTarget[] {
  return author.novels.flatMap(reviewTargetsForBook);
}

function hasEveryTarget(targets: AiNovelReviewTarget[]): boolean {
  return targets.length > 0 && targets.every((target) => selectedTargetKeys.value.has(reviewTargetKey(target)));
}

function hasSomeTarget(targets: AiNovelReviewTarget[]): boolean {
  return targets.some((target) => selectedTargetKeys.value.has(reviewTargetKey(target)));
}

function toggleTargets(targets: AiNovelReviewTarget[], checked: boolean): void {
  const selected = new Map(selectedReviewTargets.value.map((target) => [reviewTargetKey(target), target]));
  for (const target of targets) {
    const key = reviewTargetKey(target);
    if (checked) selected.set(key, target);
    else selected.delete(key);
  }
  selectedReviewTargets.value = [...selected.values()];
}

function toggleAuthorSelection(author: AiNovelReviewAuthor, checked: boolean): void {
  toggleTargets(reviewTargetsForAuthor(author), checked);
}

function toggleBookSelection(book: AiNovelReviewBook, checked: boolean): void {
  toggleTargets(reviewTargetsForBook(book), checked);
}

function toggleChapterSelection(chapter: AiNovelChapter, checked: boolean): void {
  toggleTargets([{ kind: 'chapter', id: chapter.id, expectedRevision: chapter.revision }], checked);
}

function toggleMetadataSelection(book: AiNovelReviewBook, checked: boolean): void {
  toggleTargets(metadataReviewTargets(book), checked);
}

async function confirmBatchApprove(): Promise<void> {
  if (!canBatchReview.value) return;
  try {
    await ElMessageBox.confirm(
      `将审核通过已选择的 ${selectedTargetCount.value} 项内容，并立即发布可发布内容。`,
      '批量通过审核',
      { type: 'warning', confirmButtonText: '确认通过', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  await submitBatchReview('approve');
}

function openBatchReject(): void {
  if (!canBatchReview.value) return;
  batchReviewNote.value = '';
  batchRejectOpen.value = true;
}

async function submitBatchReview(decision: 'approve' | 'reject'): Promise<void> {
  const reviewNote = batchReviewNote.value.trim();
  if (decision === 'reject' && !reviewNote) {
    ElMessage.warning('请填写具体审核意见');
    return;
  }
  batchReviewing.value = true;
  try {
    const result = await batchReviewNovels(selectedReviewTargets.value, decision, reviewNote);
    batchRejectOpen.value = false;
    batchReviewNote.value = '';
    await loadReviewQueue();
    ElMessage.success(decision === 'approve'
      ? `已通过 ${result.reviewed.length} 项审核`
      : `已退回 ${result.reviewed.length} 项内容`);
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    batchReviewing.value = false;
  }
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
    published: '管理作品',
    rejected: '修改重投',
  }[status];
}

function serializationLabel(status: string): string {
  return status === 'completed' ? '已完结' : '连载中';
}

function metadataStatusLabel(status: string): string {
  return {
    draft: '资料草稿',
    pending: '资料待审',
    approved: '资料已通过',
    rejected: '资料被退回',
  }[status] || status;
}

function metadataStatusType(status: string): 'info' | 'warning' | 'success' | 'danger' {
  return {
    draft: 'info',
    pending: 'warning',
    approved: 'success',
    rejected: 'danger',
  }[status] as 'info' | 'warning' | 'success' | 'danger';
}

function chapterChangeLabel(value: AiNovelChapter): string {
  return value.changeType === 'update' ? '修改' : '新增';
}

function chapterReviewAction(book: AiNovelReviewBook, chapter: AiNovelChapter): void {
  if (book.status === 'published') openChapterReview(chapter);
  else openNovelReview(book);
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
        <p>封面直接上传，TXT / Markdown 自动识别编码和章节；作品资料、已发布章节和新增连载均保留线上版本，审核通过后才生效。</p>
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
            <ElTableColumn label="状态" width="170">
              <template #default="scope">
                <div class="status-tags">
                  <ElTag :type="statusType(scope.row.status)" effect="light">{{ statusLabel(scope.row.status) }}</ElTag>
                  <ElTag v-if="scope.row.status === 'published'" type="info" effect="plain">
                    {{ serializationLabel(scope.row.serializationStatus) }}
                  </ElTag>
                </div>
              </template>
            </ElTableColumn>
            <ElTableColumn label="章节" width="126">
              <template #default="scope">
                <div class="chapter-count">
                  <strong>{{ scope.row.publishedChapterCount }}</strong>
                  <small>已发布 / {{ scope.row.chapterCount }} 当前</small>
                </div>
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

          <section class="review-queue-head">
            <div>
              <span class="eyebrow">AUTHOR REVIEW QUEUE</span>
              <h3>按作者、书籍和章节逐层处理</h3>
              <p>整书首发、作品资料修改和章节变更分别审核；已发布内容在审核期间继续保持线上版本。</p>
            </div>
            <div class="queue-counters" aria-label="待审核统计">
              <span><b>{{ pendingNovelCount }}</b>整书待审</span>
              <span><b>{{ pendingMetadataCount }}</b>资料待审</span>
              <span><b>{{ pendingChapterCount }}</b>章节待审</span>
            </div>
          </section>

          <div class="toolbar review-toolbar">
            <div class="toolbar-filters">
              <ElInput
                v-model="reviewQuery.q"
                clearable
                placeholder="搜索作者、作品或章节"
                :prefix-icon="Search"
                @keyup.enter="searchReview"
                @clear="searchReview"
              />
              <ElSelect v-model="reviewQuery.status" @change="searchReview">
                <ElOption label="待审核" value="pending" />
                <ElOption label="已通过" value="published" />
                <ElOption label="已退回" value="rejected" />
              </ElSelect>
              <ElButton :icon="Search" @click="searchReview">筛选</ElButton>
              <ElButton :icon="Refresh" circle title="刷新" @click="refreshReviewWorkbench" />
            </div>
            <div class="batch-actions">
              <span class="selection-summary">已选择 <strong>{{ selectedTargetCount }}</strong> 项</span>
              <ElButton
                type="primary"
                :icon="Check"
                :disabled="!canBatchReview"
                :loading="batchReviewing"
                @click="confirmBatchApprove"
              >批量通过</ElButton>
              <ElButton
                type="danger"
                :icon="CloseBold"
                :disabled="!canBatchReview"
                :loading="batchReviewing"
                @click="openBatchReject"
              >批量退回</ElButton>
            </div>
          </div>

          <ElCollapse v-loading="reviewLoading" v-model="expandedAuthors" class="author-review-collapse">
            <ElCollapseItem
              v-for="author in reviewAuthors"
              :key="authorKey(author)"
              :name="authorKey(author)"
            >
              <template #title>
                <div class="author-collapse-title">
                  <ElCheckbox
                    :model-value="hasEveryTarget(reviewTargetsForAuthor(author))"
                    :indeterminate="hasSomeTarget(reviewTargetsForAuthor(author)) && !hasEveryTarget(reviewTargetsForAuthor(author))"
                    :disabled="!reviewTargetsForAuthor(author).length || reviewQuery.status !== 'pending'"
                    aria-label="选择作者的全部待审核内容"
                    @click.stop
                    @change="toggleAuthorSelection(author, Boolean($event))"
                  />
                  <span class="author-avatar">{{ (author.ownerNickname || '作者').slice(0, 1) }}</span>
                  <div class="author-copy">
                    <strong>{{ author.ownerNickname || '未命名作者' }}</strong>
                    <small>{{ author.ownerEmail || '未记录邮箱' }}</small>
                  </div>
                  <div class="author-queue-meta">
                    <ElTag v-if="author.pendingNovelCount" type="warning" effect="plain">{{ author.pendingNovelCount }} 本整书待审</ElTag>
                    <ElTag v-if="author.pendingMetadataCount" type="warning" effect="plain">{{ author.pendingMetadataCount }} 项资料待审</ElTag>
                    <ElTag v-if="author.pendingChapterCount" type="info" effect="plain">{{ author.pendingChapterCount }} 章待审</ElTag>
                    <span>{{ author.novelCount }} 本作品</span>
                  </div>
                </div>
              </template>

              <ElCollapse v-model="expandedBooks" class="book-review-collapse">
                <ElCollapseItem
                  v-for="book in author.novels"
                  :key="bookKey(book)"
                  :name="bookKey(book)"
                >
                  <template #title>
                    <div class="book-collapse-title">
                      <ElCheckbox
                        :model-value="hasEveryTarget(reviewTargetsForBook(book))"
                        :indeterminate="hasSomeTarget(reviewTargetsForBook(book)) && !hasEveryTarget(reviewTargetsForBook(book))"
                        :disabled="!reviewTargetsForBook(book).length || reviewQuery.status !== 'pending'"
                        aria-label="选择书籍的全部待审核内容"
                        @click.stop
                        @change="toggleBookSelection(book, Boolean($event))"
                      />
                      <img v-if="book.coverUrl" :src="book.coverUrl" alt="">
                      <span v-else class="book-cover-placeholder"><ElIcon><Reading /></ElIcon></span>
                      <div class="book-copy">
                        <strong>{{ book.title }}</strong>
                        <small>笔名：{{ book.author }} · {{ book.category }} · {{ book.chapterCount }} 章</small>
                      </div>
                      <div class="book-queue-meta">
                        <ElTag :type="statusType(book.status)" effect="light">
                          {{ book.status === 'pending' ? '整书待审' : statusLabel(book.status) }}
                        </ElTag>
                        <ElTag v-if="book.status === 'published'" type="info" effect="plain">{{ serializationLabel(book.serializationStatus) }}</ElTag>
                        <ElTag v-if="book.metadataRevision" :type="metadataStatusType(book.metadataRevision.status)" effect="plain">
                          {{ metadataStatusLabel(book.metadataRevision.status) }}
                        </ElTag>
                        <span>{{ formatDateTime(book.submittedAt || book.updatedAt) }}</span>
                      </div>
                      <ElButton
                        type="primary"
                        link
                        :icon="View"
                        @click.stop="book.status === 'pending' ? openNovelReview(book) : book.metadataRevision ? openMetadataReview(book) : openNovelReview(book)"
                      >
                        {{ book.status === 'pending' ? '审核整书' : book.metadataRevision?.status === 'pending' ? '审核资料' : '查看作品' }}
                      </ElButton>
                    </div>
                  </template>

                  <section class="book-chapter-panel">
                    <header>
                      <div>
                        <strong>{{ book.status === 'pending' ? '首发稿章节' : '作品资料与章节变更' }}</strong>
                        <small>{{ book.status === 'pending' ? '这些章节随整书审核一起发布' : '资料与章节均可独立审核，线上版本在审核期间继续展示' }}</small>
                      </div>
                      <span>{{ book.metadataRevision ? '含资料修改' : `${book.chapters.length} 章` }}</span>
                    </header>
                    <article v-if="book.status === 'published' && book.metadataRevision" class="chapter-review-row metadata-review-row">
                      <ElCheckbox
                        v-if="book.metadataRevision.status === 'pending'"
                        :model-value="hasEveryTarget(metadataReviewTargets(book))"
                        aria-label="选择作品资料修改"
                        @change="toggleMetadataSelection(book, Boolean($event))"
                      />
                      <span v-else class="chapter-readonly-icon"><ElIcon><DocumentChecked /></ElIcon></span>
                      <div class="chapter-copy">
                        <strong>作品资料修改</strong>
                        <small>标题、笔名、分类、封面、简介与连载状态</small>
                      </div>
                      <div class="chapter-queue-meta">
                        <ElTag :type="metadataStatusType(book.metadataRevision.status)" effect="plain">
                          {{ metadataStatusLabel(book.metadataRevision.status) }}
                        </ElTag>
                        <span>{{ formatDateTime(book.metadataRevision.submittedAt || book.metadataRevision.updatedAt) }}</span>
                      </div>
                      <ElButton type="primary" link :icon="View" @click="openMetadataReview(book)">
                        {{ book.metadataRevision.status === 'pending' ? '审核资料' : '查看资料' }}
                      </ElButton>
                    </article>
                    <div v-if="book.chapters.length" class="chapter-review-list">
                      <article v-for="chapter in book.chapters" :key="chapter.id" class="chapter-review-row">
                        <ElCheckbox
                          v-if="book.status === 'published' && chapter.status === 'pending'"
                          :model-value="hasEveryTarget([{ kind: 'chapter', id: chapter.id, expectedRevision: chapter.revision }])"
                          aria-label="选择章节"
                          @change="toggleChapterSelection(chapter, Boolean($event))"
                        />
                        <span v-else class="chapter-readonly-icon"><ElIcon><DocumentChecked /></ElIcon></span>
                        <div class="chapter-copy">
                          <strong>第 {{ chapter.index + 1 }} 章 · {{ chapter.title }}</strong>
                          <small>{{ chapter.changeType === 'update' ? '修改已发布章节' : book.status === 'pending' ? '随整书首发' : '新增连载章节' }}</small>
                        </div>
                        <div class="chapter-queue-meta">
                          <ElTag :type="statusType(chapter.status)" effect="plain">{{ statusLabel(chapter.status) }}</ElTag>
                          <ElTag v-if="book.status === 'published'" :type="chapter.changeType === 'update' ? 'warning' : 'success'" effect="plain">
                            {{ chapterChangeLabel(chapter) }}
                          </ElTag>
                          <span>{{ formatDateTime(chapter.submittedAt || chapter.updatedAt) }}</span>
                        </div>
                        <ElButton type="primary" link :icon="View" @click="chapterReviewAction(book, chapter)">
                          {{ book.status === 'pending' ? '查看整书' : chapter.status === 'pending' ? '审核章节' : '查看章节' }}
                        </ElButton>
                      </article>
                    </div>
                    <p v-else class="empty-chapters">当前筛选条件下没有章节记录。</p>
                  </section>
                </ElCollapseItem>
              </ElCollapse>
            </ElCollapseItem>
          </ElCollapse>

          <ElEmpty
            v-if="!reviewLoading && !reviewAuthors.length"
            :image-size="72"
            :description="reviewQuery.status === 'pending' ? '当前没有待审核的作者内容' : '当前筛选条件下没有审核记录'"
          />

          <div v-if="reviewTotal > reviewQuery.pageSize" class="pagination-row">
            <ElPagination
              v-model:current-page="reviewQuery.page"
              v-model:page-size="reviewQuery.pageSize"
              background
              layout="total, sizes, prev, pager, next"
              :page-sizes="[10, 20, 50]"
              :total="reviewTotal"
              @change="loadReviewQueue"
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
    <ElDialog v-model="batchRejectOpen" title="批量退回作者修改" width="min(560px, 92vw)" append-to-body>
      <ElAlert
        type="warning"
        :closable="false"
        show-icon
        title="退回意见将同时发送给所有已选择的作者内容。"
      />
      <ElForm label-position="top" class="batch-reject-form">
        <ElFormItem label="统一审核意见" required>
          <ElInput
            v-model="batchReviewNote"
            type="textarea"
            :rows="5"
            maxlength="500"
            show-word-limit
            placeholder="请写清楚需要修改的位置和要求"
          />
        </ElFormItem>
      </ElForm>
      <template #footer>
        <ElButton :disabled="batchReviewing" @click="batchRejectOpen = false">取消</ElButton>
        <ElButton type="danger" :icon="CloseBold" :loading="batchReviewing" @click="submitBatchReview('reject')">确认退回</ElButton>
      </template>
    </ElDialog>
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

.status-tags {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 6px;
}

.pagination-row {
  display: flex;
  justify-content: flex-end;
  margin-top: 18px;
}

.review-queue-head {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 20px;
  margin-bottom: 16px;
  padding: 2px 2px 0;
}

.review-queue-head h3,
.review-queue-head p {
  margin: 0;
}

.review-queue-head h3 {
  margin-top: 5px;
  color: var(--ink-900);
  font-size: 18px;
}

.review-queue-head p {
  max-width: 700px;
  margin-top: 6px;
  color: var(--ink-500);
  font-size: 12px;
  line-height: 1.6;
}

.queue-counters,
.batch-actions,
.author-queue-meta,
.book-queue-meta,
.chapter-queue-meta {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 8px;
}

.queue-counters {
  justify-content: flex-end;
}

.queue-counters span {
  display: grid;
  gap: 2px;
  min-width: 70px;
  color: var(--ink-500);
  font-size: 11px;
  text-align: right;
}

.queue-counters b {
  color: var(--ink-900);
  font-size: 20px;
  line-height: 1;
}

.review-toolbar {
  align-items: flex-start;
}

.batch-actions {
  justify-content: flex-end;
}

.selection-summary {
  color: var(--ink-500);
  font-size: 12px;
  white-space: nowrap;
}

.selection-summary strong {
  color: var(--sakura-600);
}

.author-review-collapse,
.book-review-collapse {
  border-top: 1px solid var(--line);
}

.author-review-collapse :deep(.el-collapse-item__header),
.book-review-collapse :deep(.el-collapse-item__header) {
  height: auto;
  min-height: 68px;
  padding: 0 12px;
  border-bottom: 1px solid var(--line);
  color: inherit;
  background: var(--surface);
}

.author-review-collapse :deep(.el-collapse-item__wrap),
.book-review-collapse :deep(.el-collapse-item__wrap) {
  border-bottom: 0;
}

.author-review-collapse :deep(.el-collapse-item__content),
.book-review-collapse :deep(.el-collapse-item__content) {
  padding-bottom: 0;
}

.author-review-collapse :deep(.el-collapse-item__arrow),
.book-review-collapse :deep(.el-collapse-item__arrow) {
  margin-left: 10px;
}

.author-collapse-title,
.book-collapse-title {
  width: 100%;
  min-width: 0;
  display: grid;
  align-items: center;
  gap: 11px;
}

.author-collapse-title {
  grid-template-columns: auto 34px minmax(150px, 1fr) auto;
  padding: 12px 0;
}

.author-avatar {
  width: 34px;
  height: 34px;
  display: grid;
  place-items: center;
  border: 1px solid #f1c5d2;
  border-radius: 50%;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 14px;
  font-weight: 700;
}

.author-copy,
.book-copy,
.chapter-copy {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.author-copy strong,
.book-copy strong,
.chapter-copy strong {
  overflow: hidden;
  color: var(--ink-900);
  text-overflow: ellipsis;
  white-space: nowrap;
}

.author-copy small,
.book-copy small,
.chapter-copy small,
.book-queue-meta span,
.chapter-queue-meta span,
.author-queue-meta > span {
  overflow: hidden;
  color: var(--ink-500);
  font-size: 11px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.author-queue-meta {
  justify-content: flex-end;
}

.book-review-collapse {
  margin: 0 12px 12px 58px;
  border: 1px solid var(--line);
}

.book-review-collapse :deep(.el-collapse-item__header) {
  min-height: 76px;
  padding: 0 12px;
  background: var(--surface-muted);
}

.book-collapse-title {
  grid-template-columns: auto 39px minmax(180px, 1fr) auto auto;
  padding: 8px 0;
}

.book-collapse-title img,
.book-cover-placeholder {
  width: 39px;
  height: 52px;
  display: grid;
  place-items: center;
  border: 1px solid #f0d2dc;
  border-radius: 6px;
  color: var(--sakura-500);
  object-fit: cover;
  background: var(--sakura-50);
}

.book-queue-meta {
  justify-content: flex-end;
  min-width: 0;
}

.book-chapter-panel {
  padding: 13px 16px 16px;
  background: #fffdfd;
}

.book-chapter-panel > header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}

.book-chapter-panel > header > div {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.book-chapter-panel > header strong {
  color: var(--ink-900);
  font-size: 13px;
}

.book-chapter-panel > header small,
.book-chapter-panel > header > span {
  color: var(--ink-500);
  font-size: 11px;
}

.book-chapter-panel > header > span {
  white-space: nowrap;
}

.chapter-review-list {
  display: grid;
  border-top: 1px solid var(--line);
}

.chapter-review-row {
  display: grid;
  grid-template-columns: auto minmax(180px, 1fr) auto auto;
  align-items: center;
  gap: 11px;
  min-height: 58px;
  padding: 9px 0;
  border-bottom: 1px solid var(--line);
}

.chapter-review-row:last-child {
  border-bottom: 0;
}

.chapter-readonly-icon {
  width: 14px;
  display: grid;
  place-items: center;
  color: var(--ink-300);
}

.chapter-queue-meta {
  justify-content: flex-end;
  min-width: 0;
}

.empty-chapters {
  margin: 0;
  padding: 12px 0 2px;
  color: var(--ink-500);
  font-size: 12px;
}

.batch-reject-form {
  margin-top: 16px;
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

  .review-queue-head {
    align-items: flex-start;
    flex-direction: column;
  }

  .queue-counters,
  .batch-actions {
    justify-content: flex-start;
    width: 100%;
  }

  .batch-actions > .el-button {
    flex: 1 1 0;
  }

  .author-collapse-title {
    grid-template-columns: auto 34px minmax(0, 1fr);
  }

  .author-queue-meta {
    grid-column: 2 / -1;
    justify-content: flex-start;
  }

  .book-review-collapse {
    margin-left: 0;
  }

  .book-collapse-title {
    grid-template-columns: auto 39px minmax(0, 1fr);
  }

  .book-queue-meta,
  .book-collapse-title > .el-button {
    grid-column: 3;
    justify-content: flex-start;
  }

  .book-chapter-panel {
    padding-inline: 12px;
  }

  .chapter-review-row {
    grid-template-columns: auto minmax(0, 1fr) auto;
  }

  .chapter-queue-meta {
    grid-column: 2 / -1;
    justify-content: flex-start;
  }

  .chapter-review-row > .el-button {
    grid-column: 2 / -1;
    justify-self: start;
  }

  .pagination-row {
    overflow: auto;
    justify-content: flex-start;
  }
}
</style>
