<script setup lang="ts">
import { Check, CloseBold, DocumentChecked } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  getReviewChapterBatch,
  getReviewChapter,
  getReviewMetadata,
  getReviewNovel,
  reviewChapterBatch,
  reviewChapter,
  reviewMetadata,
  reviewNovel,
} from '@/services/ai-novels';
import type {
  AiChapterBatchReviewDetail,
  AiChapterReviewDetail,
  AiMetadataReviewDetail,
  AiNovelDetail,
  AiNovelMetadataReviewEvent,
  AiNovelReviewEvent,
} from '@/types/ai-novel';
import { formatDateTime } from '@/utils/format';

const props = defineProps<{
  modelValue: boolean;
  target: { kind: 'novel' | 'metadata' | 'chapter' | 'chapter_batch'; id: number } | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  reviewed: [];
}>();

const loading = ref(false);
const deciding = ref(false);
const novelDetail = ref<AiNovelDetail | null>(null);
const metadataDetail = ref<AiMetadataReviewDetail | null>(null);
const chapterDetail = ref<AiChapterReviewDetail | null>(null);
const chapterBatchDetail = ref<AiChapterBatchReviewDetail | null>(null);
const openChapter = ref<number | string>('');
const rejectionOpen = ref(false);
const rejectionNote = ref('');
const rejectionTemplate = ref('');
const rejectionTemplates = [
  '作品简介与正文内容不一致，请补充或修正。',
  '章节结构识别有误，请调整章节标题和正文范围。',
  '正文存在明显缺失或重复内容，请检查后重新提交。',
  '封面不符合展示要求，请上传清晰且与作品相关的封面。',
];

const isNovel = computed(() => props.target?.kind === 'novel');
const isMetadata = computed(() => props.target?.kind === 'metadata');
const isChapterBatch = computed(() => props.target?.kind === 'chapter_batch');
const title = computed(() => isNovel.value
  ? novelDetail.value?.item.title || '整书审核'
  : isMetadata.value
    ? metadataDetail.value?.item.title || '作品资料修改'
    : isChapterBatch.value
      ? `章节提交批次 · ${chapterBatchDetail.value?.item.chapterCount || 0} 章`
    : chapterDetail.value?.item.title || '章节审核');
const pending = computed(() => isNovel.value
  ? novelDetail.value?.item.status === 'pending'
  : isMetadata.value
    ? metadataDetail.value?.item.status === 'pending'
    : isChapterBatch.value
      ? chapterBatchDetail.value?.item.status === 'pending'
    : chapterDetail.value?.item.status === 'pending');
const isChapterRevision = computed(() =>
  !isNovel.value && chapterDetail.value?.item.changeType === 'update',
);
const chapterChangeLabel = computed(() => isChapterRevision.value ? '修改已发布章节' : '新增连载章节');
const approveLabel = computed(() => isMetadata.value
  ? '通过并更新资料'
  : isChapterBatch.value
    ? '通过并发布本批章节'
  : isChapterRevision.value ? '通过并更新' : '通过并发布');
const reviews = computed<Array<AiNovelReviewEvent | AiNovelMetadataReviewEvent>>(() =>
  isNovel.value
    ? novelDetail.value?.reviews || []
    : isMetadata.value
      ? metadataDetail.value?.reviews || []
      : isChapterBatch.value
        ? chapterBatchDetail.value?.reviews || []
      : chapterDetail.value?.reviews || [],
);

watch(
  () => props.modelValue,
  (open) => {
    if (open) void loadDetail();
  },
);

watch(
  () => props.target,
  () => {
    if (props.modelValue) void loadDetail();
  },
  { deep: true },
);

async function loadDetail(): Promise<void> {
  if (!props.target) return;
  loading.value = true;
  novelDetail.value = null;
  metadataDetail.value = null;
  chapterDetail.value = null;
  chapterBatchDetail.value = null;
  try {
    if (props.target.kind === 'novel') {
      novelDetail.value = await getReviewNovel(props.target.id);
      openChapter.value = novelDetail.value.chapters[0]?.id || '';
    } else if (props.target.kind === 'metadata') {
      metadataDetail.value = await getReviewMetadata(props.target.id);
    } else if (props.target.kind === 'chapter_batch') {
      chapterBatchDetail.value = await getReviewChapterBatch(props.target.id);
      openChapter.value = chapterBatchDetail.value.chapters[0]?.id || '';
    } else {
      chapterDetail.value = await getReviewChapter(props.target.id);
    }
  } catch (error) {
    ElMessage.error(errorMessage(error));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

function selectRejectionTemplate(value: string): void {
  if (value) rejectionNote.value = value;
}

function openRejection(): void {
  rejectionTemplate.value = '';
  rejectionNote.value = '';
  rejectionOpen.value = true;
}

async function decide(decision: 'approve' | 'reject'): Promise<void> {
  if (!props.target || !pending.value) return;
  if (decision === 'reject' && !rejectionNote.value.trim()) {
    ElMessage.warning('请填写具体的驳回原因，创作者需要据此修改');
    return;
  }
  const revision = isNovel.value
    ? novelDetail.value?.item.revision
    : isMetadata.value
      ? metadataDetail.value?.item.revision
      : isChapterBatch.value
        ? chapterBatchDetail.value?.item.revision
      : chapterDetail.value?.item.revision;
  if (!revision) return;

  deciding.value = true;
  try {
    if (props.target.kind === 'novel') {
      await reviewNovel(props.target.id, decision, revision, rejectionNote.value.trim());
    } else if (props.target.kind === 'metadata') {
      await reviewMetadata(props.target.id, decision, revision, rejectionNote.value.trim());
    } else if (props.target.kind === 'chapter_batch') {
      await reviewChapterBatch(props.target.id, decision, revision, rejectionNote.value.trim());
    } else {
      await reviewChapter(props.target.id, decision, revision, rejectionNote.value.trim());
    }
    rejectionOpen.value = false;
    emit('reviewed');
    emit('update:modelValue', false);
    ElMessage.success(decision === 'approve'
      ? (isMetadata.value
        ? '审核通过，线上作品资料已更新'
        : isChapterBatch.value
          ? '审核通过，本次提交的章节已整体发布'
        : isChapterRevision.value ? '审核通过，线上章节已更新' : '审核通过，内容已发布')
      : '已退回创作者修改');
  } catch (error) {
    ElMessage.error(errorMessage(error));
    if (error instanceof ApiError && error.code === 'revision_conflict') {
      await loadDetail();
    }
  } finally {
    deciding.value = false;
  }
}

function decisionLabel(decision: string): string {
  return {
    approve: '审核通过',
    reject: '退回修改',
    direct_publish: '管理员直接发布',
  }[decision] || decision;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '加载审核内容失败';
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="novel-review-drawer"
    size="min(920px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="review-heading">
        <div class="review-icon"><ElIcon><DocumentChecked /></ElIcon></div>
        <div>
          <span class="eyebrow">REVIEW WORKBENCH</span>
          <h2>{{ title }}</h2>
          <p>{{ isNovel ? '整书首次发布审核' : isMetadata ? `《${metadataDetail?.novel.title || ''}》的作品资料修改` : isChapterBatch ? `《${chapterBatchDetail?.novel.title || ''}》本次提交的 ${chapterBatchDetail?.item.chapterCount || 0} 章将整体审核` : `《${chapterDetail?.item.novelTitle || ''}》${chapterChangeLabel}` }}</p>
        </div>
      </div>
    </template>

    <div v-loading="loading" class="review-body">
      <template v-if="novelDetail">
        <section class="novel-overview">
          <img v-if="novelDetail.item.coverUrl" :src="novelDetail.item.coverUrl" alt="作品封面">
          <div v-else class="review-cover-missing">未上传封面</div>
          <div class="novel-overview-copy">
            <ElDescriptions :column="2" border>
              <ElDescriptionsItem label="作者">{{ novelDetail.item.author }}</ElDescriptionsItem>
              <ElDescriptionsItem label="分类">{{ novelDetail.item.category }}</ElDescriptionsItem>
              <ElDescriptionsItem label="连载状态">
                {{ novelDetail.item.serializationStatus === 'completed' ? '已完结' : '连载中' }}
              </ElDescriptionsItem>
              <ElDescriptionsItem label="作者">
                {{ novelDetail.item.ownerNickname }} · {{ novelDetail.item.ownerEmail }}
              </ElDescriptionsItem>
              <ElDescriptionsItem label="提交版本">R{{ novelDetail.item.revision }}</ElDescriptionsItem>
              <ElDescriptionsItem label="作品简介" :span="2">
                {{ novelDetail.item.description }}
              </ElDescriptionsItem>
            </ElDescriptions>
          </div>
        </section>

        <section class="review-section">
          <header>
            <div><span class="eyebrow">FULL TEXT</span><h3>正文逐章审核</h3></div>
            <ElTag type="info">{{ novelDetail.chapters.length }} 章</ElTag>
          </header>
          <ElCollapse v-model="openChapter" accordion class="chapter-review-list">
            <ElCollapseItem
              v-for="(chapter, index) in novelDetail.chapters"
              :key="chapter.id"
              :name="chapter.id"
            >
              <template #title>
                <span class="chapter-review-title">
                  <b>{{ index + 1 }}</b>
                  <strong>{{ chapter.title }}</strong>
                  <small>{{ (chapter.content || '').length.toLocaleString() }} 字</small>
                </span>
              </template>
              <article v-if="openChapter === chapter.id" class="chapter-text">{{ chapter.content }}</article>
            </ElCollapseItem>
          </ElCollapse>
        </section>
      </template>

      <template v-else-if="metadataDetail">
        <section class="review-section metadata-comparison-section">
          <header>
            <div><span class="eyebrow">METADATA DIFF</span><h3>当前线上资料与待审修改稿</h3></div>
            <ElTag type="warning" effect="plain">审核通过后统一替换线上资料</ElTag>
          </header>
          <div class="metadata-comparison">
            <section class="metadata-version">
              <span>当前线上资料</span>
              <div class="metadata-cover-row">
                <img v-if="metadataDetail.novel.coverUrl" :src="metadataDetail.novel.coverUrl" alt="当前线上封面">
                <div v-else class="metadata-cover-missing">无封面</div>
                <ElDescriptions :column="1" border>
                  <ElDescriptionsItem label="作品名称">{{ metadataDetail.novel.title }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="作者笔名">{{ metadataDetail.novel.author }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="作品分类">{{ metadataDetail.novel.category }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="连载状态">{{ metadataDetail.novel.serializationStatus === 'completed' ? '已完结' : '连载中' }}</ElDescriptionsItem>
                </ElDescriptions>
              </div>
              <article class="metadata-description">{{ metadataDetail.novel.description }}</article>
            </section>
            <section class="metadata-version">
              <span>待审修改稿</span>
              <div class="metadata-cover-row">
                <img v-if="metadataDetail.item.coverUrl" :src="metadataDetail.item.coverUrl" alt="待审封面">
                <div v-else class="metadata-cover-missing">无封面</div>
                <ElDescriptions :column="1" border>
                  <ElDescriptionsItem label="作品名称">{{ metadataDetail.item.title }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="作者笔名">{{ metadataDetail.item.penName }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="作品分类">{{ metadataDetail.item.category }}</ElDescriptionsItem>
                  <ElDescriptionsItem label="连载状态">{{ metadataDetail.item.serializationStatus === 'completed' ? '已完结' : '连载中' }}</ElDescriptionsItem>
                </ElDescriptions>
              </div>
              <article class="metadata-description">{{ metadataDetail.item.description }}</article>
            </section>
          </div>
        </section>
      </template>

      <template v-else-if="chapterBatchDetail">
        <ElDescriptions :column="2" border>
          <ElDescriptionsItem label="所属作品">{{ chapterBatchDetail.novel.title }}</ElDescriptionsItem>
          <ElDescriptionsItem label="本次提交">{{ chapterBatchDetail.item.chapterCount }} 章</ElDescriptionsItem>
          <ElDescriptionsItem label="作者">
            {{ chapterBatchDetail.item.ownerNickname }} · {{ chapterBatchDetail.item.ownerEmail }}
          </ElDescriptionsItem>
          <ElDescriptionsItem label="提交版本">R{{ chapterBatchDetail.item.revision }}</ElDescriptionsItem>
          <ElDescriptionsItem label="审核规则" :span="2">本批章节只能整体通过或整体退回，不会部分发布。</ElDescriptionsItem>
        </ElDescriptions>
        <section class="review-section chapter-batch-review-section">
          <header>
            <div><span class="eyebrow">SUBMISSION BATCH</span><h3>本次提交章节</h3></div>
            <ElTag :type="chapterBatchDetail.item.status === 'pending' ? 'warning' : 'success'" effect="plain">
              {{ chapterBatchDetail.item.status === 'pending' ? '待审核' : chapterBatchDetail.item.status === 'published' ? '已发布' : '已退回' }}
            </ElTag>
          </header>
          <ElCollapse v-model="openChapter" accordion class="chapter-review-list">
            <ElCollapseItem
              v-for="chapter in chapterBatchDetail.chapters"
              :key="chapter.id"
              :name="chapter.id"
            >
              <template #title>
                <span class="chapter-review-title">
                  <b>{{ chapter.index + 1 }}</b>
                  <strong>{{ chapter.title }}</strong>
                  <small>{{ chapter.changeType === 'update' ? '修改' : '新增' }} · {{ (chapter.content || '').length.toLocaleString() }} 字</small>
                </span>
              </template>
              <div v-if="chapter.changeType === 'update'" class="chapter-comparison">
                <section>
                  <span>当前线上版本</span>
                  <h4>{{ chapter.originalTitle }}</h4>
                  <article class="chapter-text">{{ chapter.originalContent }}</article>
                </section>
                <section>
                  <span>待审修改稿</span>
                  <h4>{{ chapter.title }}</h4>
                  <article class="chapter-text">{{ chapter.content }}</article>
                </section>
              </div>
              <article v-else class="chapter-text">{{ chapter.content }}</article>
            </ElCollapseItem>
          </ElCollapse>
        </section>
      </template>

      <template v-else-if="chapterDetail">
        <ElDescriptions :column="2" border>
          <ElDescriptionsItem label="所属作品">{{ chapterDetail.item.novelTitle }}</ElDescriptionsItem>
          <ElDescriptionsItem label="章节序号">第 {{ chapterDetail.item.index + 1 }} 章</ElDescriptionsItem>
          <ElDescriptionsItem label="作者">
            {{ chapterDetail.item.ownerNickname }} · {{ chapterDetail.item.ownerEmail }}
          </ElDescriptionsItem>
          <ElDescriptionsItem label="提交版本">R{{ chapterDetail.item.revision }}</ElDescriptionsItem>
          <ElDescriptionsItem label="变更类型">
            <ElTag :type="isChapterRevision ? 'warning' : 'success'" effect="plain">
              {{ chapterChangeLabel }}
            </ElTag>
          </ElDescriptionsItem>
        </ElDescriptions>
        <section v-if="isChapterRevision" class="review-section chapter-comparison-section">
          <header>
            <div><span class="eyebrow">REVISION DIFF</span><h3>线上版本与修改稿对照</h3></div>
            <ElTag type="warning" effect="plain">审核通过后替换线上内容</ElTag>
          </header>
          <div class="chapter-comparison">
            <section>
              <span>当前线上版本</span>
              <h4>{{ chapterDetail.item.originalTitle }}</h4>
              <article class="chapter-text">{{ chapterDetail.item.originalContent }}</article>
            </section>
            <section>
              <span>待审修改稿</span>
              <h4>{{ chapterDetail.item.title }}</h4>
              <article class="chapter-text">{{ chapterDetail.item.content }}</article>
            </section>
          </div>
        </section>
        <section v-else class="review-section chapter-only-section">
          <header><div><span class="eyebrow">CHAPTER TEXT</span><h3>{{ chapterDetail.item.title }}</h3></div></header>
          <article class="chapter-text">{{ chapterDetail.item.content }}</article>
        </section>
      </template>

      <section v-if="reviews.length" class="review-section history-section">
        <header><div><span class="eyebrow">HISTORY</span><h3>审核记录</h3></div></header>
        <ElTimeline>
          <ElTimelineItem
            v-for="event in reviews"
            :key="event.id"
            :type="event.decision === 'reject' ? 'danger' : 'success'"
            :timestamp="formatDateTime(event.createdAt)"
          >
            <strong>{{ decisionLabel(event.decision) }}</strong>
            <span> · {{ event.reviewerNickname || event.reviewerEmail }}</span>
            <p v-if="event.note">{{ event.note }}</p>
          </ElTimelineItem>
        </ElTimeline>
      </section>
    </div>

    <template #footer>
      <div class="review-footer">
        <span v-if="pending">
          {{ isMetadata ? '请对照线上资料确认标题、简介、封面和连载状态修改。' : isChapterBatch ? '请确认本批全部章节均可发布；退回时将整批章节一并退回作者。' : isChapterRevision ? '请对照线上版本确认修改内容。' : '请确认正文完整、章节边界正确、封面与简介合规。' }}
        </span>
        <span v-else>该内容已完成审核。</span>
        <ElButton @click="emit('update:modelValue', false)">关闭</ElButton>
        <ElButton v-if="pending" type="danger" plain :icon="CloseBold" @click="openRejection">退回修改</ElButton>
        <ElPopconfirm
          v-if="pending"
          :title="isMetadata ? '确认通过并统一更新当前线上作品资料？' : isChapterBatch ? '确认通过并整体发布本次提交的全部章节？' : isChapterRevision ? '确认通过并替换当前线上章节？' : '确认审核通过并立即发布？'"
          width="220"
          :confirm-button-text="approveLabel"
          cancel-button-text="取消"
          @confirm="decide('approve')"
        >
          <template #reference>
            <ElButton type="primary" :icon="Check" :loading="deciding">{{ approveLabel }}</ElButton>
          </template>
        </ElPopconfirm>
      </div>
    </template>
  </ElDrawer>

  <ElDialog v-model="rejectionOpen" title="退回创作者修改" width="min(560px, 92vw)" append-to-body>
    <ElAlert
      type="warning"
      :closable="false"
      title="请写清楚具体位置和修改要求，避免创作者反复猜测。"
      show-icon
    />
    <ElForm label-position="top" class="rejection-form">
      <ElFormItem label="常用原因">
        <ElSelect
          v-model="rejectionTemplate"
          clearable
          placeholder="选择后可继续编辑"
          @change="selectRejectionTemplate"
        >
          <ElOption v-for="template in rejectionTemplates" :key="template" :label="template" :value="template" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="具体审核意见" required>
        <ElInput
          v-model="rejectionNote"
          type="textarea"
          :rows="6"
          maxlength="500"
          show-word-limit
          placeholder="例如：第二章第 3 段出现重复内容，请删除后重新提交。"
        />
      </ElFormItem>
    </ElForm>
    <template #footer>
      <ElButton @click="rejectionOpen = false">取消</ElButton>
      <ElButton type="danger" :loading="deciding" @click="decide('reject')">确认退回</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.review-heading,
.review-section > header,
.review-footer,
.chapter-review-title {
  display: flex;
  align-items: center;
}

.review-heading {
  gap: 12px;
}

.review-icon {
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: 14px;
  color: var(--sakura-600);
  background: var(--sakura-100);
  font-size: 22px;
}

.review-heading h2,
.review-heading p,
.review-section h3 {
  margin: 0;
}

.review-heading h2 {
  margin-top: 3px;
  font-size: 20px;
}

.review-heading p {
  margin-top: 4px;
  color: var(--ink-500);
  font-size: 12px;
}

.review-body {
  min-height: 380px;
  display: grid;
  gap: 18px;
}

.novel-overview {
  display: grid;
  grid-template-columns: 128px minmax(0, 1fr);
  gap: 18px;
}

.novel-overview > img,
.review-cover-missing {
  width: 128px;
  aspect-ratio: 3 / 4;
  border-radius: 12px;
}

.novel-overview > img {
  object-fit: cover;
  box-shadow: var(--shadow-sm);
}

.review-cover-missing {
  display: grid;
  place-items: center;
  border: 1px dashed var(--line);
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 12px;
}

.review-section {
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 16px;
  background: white;
}

.review-section > header {
  justify-content: space-between;
  gap: 16px;
  padding: 16px 18px;
  border-bottom: 1px solid var(--line);
}

.review-section h3 {
  margin-top: 3px;
  font-size: 16px;
}

.chapter-review-list {
  border: 0;
}

.chapter-review-list :deep(.el-collapse-item__header) {
  min-height: 54px;
  height: auto;
  padding: 8px 18px;
}

.chapter-review-list :deep(.el-collapse-item__content) {
  padding: 0;
}

.chapter-review-title {
  min-width: 0;
  flex: 1;
  gap: 10px;
}

.chapter-review-title b {
  width: 27px;
  height: 27px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  color: var(--sakura-600);
  background: var(--sakura-100);
  font-size: 12px;
}

.chapter-review-title strong {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.chapter-review-title small {
  margin-left: auto;
  color: var(--ink-300);
}

.chapter-text {
  max-height: 620px;
  overflow: auto;
  margin: 0;
  padding: 22px 24px 30px;
  color: #343139;
  background: #fffdfd;
  font-size: 15px;
  line-height: 2;
  white-space: pre-wrap;
  word-break: break-word;
}

.chapter-only-section .chapter-text {
  min-height: 360px;
}

.chapter-comparison {
  display: grid;
  grid-template-columns: 1fr 1fr;
}

.metadata-comparison {
  display: grid;
  grid-template-columns: 1fr 1fr;
}

.metadata-version {
  min-width: 0;
  padding: 16px 18px 20px;
}

.metadata-version + .metadata-version {
  border-left: 1px solid var(--line);
}

.metadata-version > span {
  display: block;
  margin-bottom: 12px;
  color: var(--ink-500);
  font-size: 11px;
  font-weight: 700;
}

.metadata-cover-row {
  display: grid;
  grid-template-columns: 88px minmax(0, 1fr);
  gap: 12px;
  align-items: start;
}

.metadata-cover-row > img,
.metadata-cover-missing {
  width: 88px;
  aspect-ratio: 3 / 4;
  border-radius: 8px;
}

.metadata-cover-row > img {
  object-fit: cover;
}

.metadata-cover-missing {
  display: grid;
  place-items: center;
  border: 1px dashed var(--line);
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 11px;
}

.metadata-description {
  min-height: 92px;
  margin-top: 14px;
  color: #343139;
  line-height: 1.75;
  white-space: pre-wrap;
  word-break: break-word;
}

.chapter-comparison > section {
  min-width: 0;
}

.chapter-comparison > section + section {
  border-left: 1px solid var(--line);
}

.chapter-comparison > section > span {
  display: block;
  padding: 12px 18px 0;
  color: var(--ink-500);
  font-size: 11px;
  font-weight: 700;
}

.chapter-comparison h4 {
  margin: 5px 18px 0;
  font-size: 15px;
}

.chapter-comparison .chapter-text {
  min-height: 360px;
  max-height: 560px;
  padding-top: 14px;
}

.history-section :deep(.el-timeline) {
  margin: 0;
  padding: 22px 28px 10px;
}

.history-section p {
  margin: 7px 0 0;
  color: var(--ink-500);
  line-height: 1.6;
}

.review-footer {
  justify-content: flex-end;
  gap: 10px;
}

.review-footer > span:first-child {
  margin-right: auto;
  color: var(--ink-500);
  font-size: 12px;
}

.rejection-form {
  margin-top: 18px;
}

.rejection-form :deep(.el-select) {
  width: 100%;
}

@media (max-width: 680px) {
  .novel-overview {
    grid-template-columns: 1fr;
  }

  .novel-overview > img,
  .review-cover-missing {
    width: 112px;
  }

  .review-footer {
    flex-wrap: wrap;
  }

  .review-footer > span:first-child {
    width: 100%;
  }

  .chapter-comparison {
    grid-template-columns: 1fr;
  }

  .metadata-comparison {
    grid-template-columns: 1fr;
  }

  .chapter-comparison > section + section {
    border-top: 1px solid var(--line);
    border-left: 0;
  }

  .metadata-version + .metadata-version {
    border-top: 1px solid var(--line);
    border-left: 0;
  }
}
</style>
