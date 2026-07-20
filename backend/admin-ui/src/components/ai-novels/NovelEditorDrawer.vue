<script setup lang="ts">
import {
  ArrowDown,
  ArrowUp,
  Delete,
  DocumentAdd,
  Plus,
  UploadFilled,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import type {
  UploadFile,
  UploadFiles,
  UploadInstance,
  UploadRequestOptions,
} from 'element-plus';
import { computed, nextTick, onBeforeUnmount, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  getCreatorNovel,
  saveNovelDraft,
  submitNovel,
  uploadNovelCover,
} from '@/services/ai-novels';
import type {
  AiNovelChapter,
  AiNovelDetail,
  AiNovelSerializationStatus,
  EditableChapter,
} from '@/types/ai-novel';
import {
  maxNovelChapterCount,
  parseNovelFiles,
} from '@/utils/novel-import';

type UploadAjaxError = Parameters<UploadRequestOptions['onError']>[0];
type EditorIssueSection = 'metadata' | 'chapters' | 'footer';
type EditorIssueField = 'title' | 'penName' | 'category' | 'cover' | 'description';

interface EditorIssue {
  message: string;
  section: EditorIssueSection;
  field?: EditorIssueField;
}

const props = defineProps<{
  modelValue: boolean;
  novelId: number | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [];
}>();

const categories = ['AI原创', '玄幻', '奇幻', '科幻', '都市', '悬疑', '历史', '轻小说', '现实'];
const detail = ref<AiNovelDetail | null>(null);
const loading = ref(false);
const saving = ref(false);
const submitting = ref(false);
const uploadingCover = ref(false);
const importing = ref(false);
const importSummary = ref('');
const openSections = ref(['metadata']);
const comparisonOpen = ref<string[]>([]);
const chapters = ref<EditableChapter[]>([]);
const previewChapters = ref<EditableChapter[]>([]);
const selectedChapterId = ref('');
const savedSnapshot = ref('');
const editorIssue = ref<EditorIssue | null>(null);
const metadataSectionRef = ref<HTMLElement | null>(null);
const chapterSectionRef = ref<HTMLElement | null>(null);
const novelUploadRef = ref<UploadInstance>();
let novelImportTimer: ReturnType<typeof setTimeout> | undefined;

const form = reactive({
  title: '',
  penName: '',
  category: 'AI原创',
  coverUrl: '',
  description: '',
  serializationStatus: 'ongoing' as AiNovelSerializationStatus,
});

const status = computed(() => detail.value?.item.status || 'draft');
const isPending = computed(() => status.value === 'pending');
const isPublished = computed(() => status.value === 'published');
const metadataRevision = computed(() => detail.value?.metadataRevision || null);
const metadataPending = computed(() => metadataRevision.value?.status === 'pending');
const metadataLocked = computed(() => isPending.value || metadataPending.value);
const visibleChapters = computed(() => isPending.value ? previewChapters.value : chapters.value);
const activeChapter = computed(() =>
  visibleChapters.value.find((chapter) => chapter.clientId === selectedChapterId.value)
  || visibleChapters.value[0]
  || null,
);
const activeChapterLocked = computed(() => isPending.value || Boolean(activeChapter.value?.locked));
const characterCount = computed(() => chapters.value.reduce(
  (total, chapter) => total + chapter.title.length + chapter.content.length,
  0,
));
const publishedChapterCount = computed(() =>
  detail.value?.chapters.filter(
    (chapter) => chapter.status === 'published' && chapter.replacesChapterId == null,
  ).length || 0,
);
const pendingSerialCount = computed(() =>
  detail.value?.chapters.filter((chapter) => chapter.status === 'pending').length || 0,
);
const rejectedChapterSummary = computed(() =>
  (detail.value?.chapters || [])
    .filter((chapter) => chapter.status === 'rejected')
    .map((chapter) => `${chapter.title}：${chapter.reviewNote || '请按审核要求修改'}`)
    .join('；'),
);
const reviewableChapterCount = computed(() => chapters.value.filter(isChapterReviewable).length);
const metadataHasChanges = computed(() => {
  if (!isPublished.value || !detail.value) return false;
  const online = detail.value.item;
  return form.title !== online.title
    || form.penName !== online.author
    || form.category !== online.category
    || form.coverUrl !== online.coverUrl
    || form.description !== online.description
    || form.serializationStatus !== online.serializationStatus;
});
const metadataChangeLabel = computed(() => {
  const revision = metadataRevision.value;
  if (!revision) return '';
  return {
    draft: '资料修改草稿',
    pending: '资料审核中',
    rejected: '资料修改被退回',
    approved: '资料修改已生效',
  }[revision.status] || '';
});
const submissionLabel = computed(() => {
  if (!isPublished.value) return status.value === 'rejected' ? '修改并重新提交' : '提交审核';
  const changes: string[] = [];
  if (metadataHasChanges.value) changes.push('资料修改');
  if (reviewableChapterCount.value) changes.push(`${reviewableChapterCount.value} 章变更`);
  return changes.length ? `提交审核：${changes.join('、')}` : '提交审核';
});
const dirty = computed(() => Boolean(detail.value) && serializeDraft() !== savedSnapshot.value);

watch(
  () => props.modelValue,
  (open) => {
    if (open) void loadDetail();
  },
);

watch(
  () => props.novelId,
  () => {
    if (props.modelValue) void loadDetail();
  },
);

watch(
  () => [
    form.title,
    form.penName,
    form.category,
    form.coverUrl,
    form.description,
    form.serializationStatus,
  ],
  () => {
    const current = editorIssue.value;
    if (!current || current.section !== 'metadata') return;
    const nextIssue = validateSubmission();
    if (!nextIssue || nextIssue.message !== current.message) editorIssue.value = null;
  },
);

onBeforeUnmount(() => {
  if (novelImportTimer) clearTimeout(novelImportTimer);
});

async function loadDetail(): Promise<void> {
  if (!props.novelId) return;
  loading.value = true;
  try {
    applyDetail(await getCreatorNovel(props.novelId));
  } catch (error) {
    ElMessage.error(errorMessage(error));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

function applyDetail(data: AiNovelDetail): void {
  detail.value = data;
  const proposedMetadata = data.item.status === 'published' ? data.metadataRevision : null;
  Object.assign(form, {
    title: proposedMetadata?.title || data.item.title,
    penName: proposedMetadata?.penName || data.item.author,
    category: proposedMetadata?.category || data.item.category,
    coverUrl: proposedMetadata?.coverUrl || data.item.coverUrl,
    description: proposedMetadata?.description || data.item.description,
    serializationStatus: proposedMetadata?.serializationStatus || data.item.serializationStatus || 'ongoing',
  });
  chapters.value = data.item.status === 'published'
    ? mergePublishedChapters(data.chapters)
    : data.chapters
        .filter((chapter) => chapter.status === 'draft' || chapter.status === 'rejected')
        .map(chapterToEditable);
  previewChapters.value = data.chapters.map(chapterToEditable);
  selectedChapterId.value = (isPending.value ? previewChapters.value[0] : chapters.value[0])?.clientId || '';
  importSummary.value = '';
  comparisonOpen.value = [];
  editorIssue.value = null;
  savedSnapshot.value = serializeDraft();
}

async function saveDraft(showMessage = true): Promise<AiNovelDetail | null> {
  if (!props.novelId || !detail.value || isPending.value) return null;
  const issue = validateEditableChapters(false);
  if (issue) {
    await presentEditorIssue({ message: issue, section: 'chapters' });
    return null;
  }
  saving.value = true;
  try {
    const data = await saveNovelDraft(props.novelId, {
      expectedRevision: detail.value.item.revision,
      title: form.title,
      penName: form.penName,
      category: form.category,
      coverUrl: form.coverUrl,
      description: form.description,
      serializationStatus: form.serializationStatus,
      chapters: chapters.value.map((chapter) => ({
        id: chapter.id,
        publishedChapterId: chapter.publishedChapterId,
        title: chapter.title,
        content: chapter.content,
      })),
    });
    applyDetail(data);
    emit('saved');
    if (showMessage) ElMessage.success('草稿已保存');
    return data;
  } catch (error) {
    await handleMutationError(error);
    return null;
  } finally {
    saving.value = false;
  }
}

async function submitForReview(): Promise<void> {
  if (!props.novelId || !detail.value) return;
  const issue = validateSubmission();
  if (issue) {
    await presentEditorIssue(issue);
    return;
  }
  editorIssue.value = null;
  submitting.value = true;
  try {
    const saved = await saveDraft(false);
    if (!saved) return;
    const submitted = await submitNovel(props.novelId, saved.item.revision);
    applyDetail(submitted);
    emit('saved');
    ElMessage.success(isPublished.value
      ? '资料或章节变更已提交审核，线上版本将保持不变直至通过。'
      : '作品已提交审核');
    emit('update:modelValue', false);
  } catch (error) {
    await handleMutationError(error);
  } finally {
    submitting.value = false;
  }
}

async function handleCoverUpload(options: UploadRequestOptions): Promise<void> {
  const file = options.file;
  if (file.size > 5 * 1024 * 1024) {
    const error = new Error('封面不能超过 5MB');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
    const error = new Error('封面仅支持 JPG、PNG 或 WebP');
    options.onError(asUploadError(error));
    ElMessage.warning(error.message);
    return;
  }
  uploadingCover.value = true;
  try {
    const result = await uploadNovelCover(file);
    form.coverUrl = result.url;
    options.onSuccess(result);
    ElMessage.success('封面上传成功，保存草稿后生效');
  } catch (error) {
    options.onError(asUploadError(error));
    ElMessage.error(errorMessage(error));
  } finally {
    uploadingCover.value = false;
  }
}

function handleNovelFileSelection(_file: UploadFile, uploadFiles: UploadFiles): void {
  const files = uploadFiles.flatMap((item) => item.raw ? [item.raw] : []);
  if (!files.length) return;
  if (novelImportTimer) clearTimeout(novelImportTimer);
  novelImportTimer = setTimeout(() => {
    novelImportTimer = undefined;
    void handleNovelImport(files);
  }, 0);
}

function handleNovelImportExceed(): void {
  ElMessage.warning(`一次最多选择 ${maxNovelChapterCount} 个章节文件`);
}

async function handleNovelImport(files: File[]): Promise<void> {
  if (!files.length || importing.value) return;
  importing.value = true;
  try {
    const parsed = await parseNovelFiles(files);
    const replaceableChapters = isPublished.value
      ? chapters.value.filter((chapter) => chapter.publishedChapterId == null && !chapter.locked)
      : chapters.value;
    if (replaceableChapters.length) {
      await ElMessageBox.confirm(
        `导入将替换当前 ${replaceableChapters.length} 个未提交新增章节，是否继续？`,
        '替换章节',
        { type: 'warning', confirmButtonText: '继续导入', cancelButtonText: '取消' },
      );
    }
    const importedChapters = parsed.chapters.map((chapter) => ({
      ...chapter,
      workflowStatus: 'draft' as const,
      changeType: 'add' as const,
      locked: false,
    }));
    chapters.value = isPublished.value
      ? [
          ...chapters.value.filter(
            (chapter) => chapter.publishedChapterId != null || chapter.locked,
          ),
          ...importedChapters,
        ]
      : importedChapters;
    selectedChapterId.value = importedChapters[0]?.clientId || chapters.value[0]?.clientId || '';
    clearEditorIssue('chapters');
    const encodingSummary = [...new Set(parsed.encodings)].join(' / ');
    importSummary.value = parsed.fileCount === 1
      ? `${parsed.orderedFileNames[0]} · ${encodingSummary} · ${parsed.chapters.length} 章 · ${parsed.characterCount.toLocaleString()} 字符`
      : `${parsed.fileCount} 个文件 · 已按文件名排序 · ${encodingSummary} · ${parsed.chapters.length} 章 · ${parsed.characterCount.toLocaleString()} 字符`;
    if (!isPublished.value && parsed.fileCount === 1 && form.title === '未命名作品') {
      form.title = parsed.orderedFileNames[0]?.replace(/\.(?:txt|md)$/i, '') || form.title;
    }
    ElMessage.success(
      parsed.fileCount === 1
        ? `已识别 ${parsed.chapters.length} 个章节，请预览后保存`
        : `已导入 ${parsed.fileCount} 个文件为 ${parsed.chapters.length} 个章节，请预览后保存`,
    );
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    if (reason !== 'cancel' && reason !== 'close') {
      ElMessage.error(errorMessage(error));
    }
  } finally {
    importing.value = false;
    novelUploadRef.value?.clearFiles();
  }
}

function addChapter(): void {
  const chapter = editableChapter(`第 ${chapters.value.length + 1} 章`, '', Date.now(), {
    workflowStatus: 'draft',
    changeType: 'add',
  });
  chapters.value.push(chapter);
  selectedChapterId.value = chapter.clientId;
  clearEditorIssue('chapters');
}

function removeChapter(index: number): void {
  const chapter = chapters.value[index];
  if (!chapter || chapter.locked) return;
  if (chapter.publishedChapterId != null) {
    if (!chapterChanged(chapter)) return;
    chapter.id = chapter.publishedChapterId;
    chapter.title = chapter.originalTitle || chapter.title;
    chapter.content = chapter.originalContent || chapter.content;
    chapter.workflowStatus = 'published';
    chapter.changeType = 'published';
    chapter.reviewNote = '';
    clearEditorIssue('chapters');
    return;
  }
  chapters.value.splice(index, 1);
  selectedChapterId.value = chapters.value[Math.min(index, chapters.value.length - 1)]?.clientId || '';
  clearEditorIssue('chapters');
}

function moveChapter(index: number, direction: -1 | 1): void {
  if (!canMoveChapter(index, direction)) return;
  const target = index + direction;
  const [chapter] = chapters.value.splice(index, 1);
  if (!chapter) return;
  chapters.value.splice(target, 0, chapter);
  clearEditorIssue('chapters');
}

function validateEditableChapters(requireOne: boolean): string {
  if (requireOne && (isPublished.value ? reviewableChapterCount.value === 0 : !chapters.value.length)) {
    return isPublished.value
      ? '请先修改已发布章节或添加新的连载章节'
      : '请先导入或添加正文章节';
  }
  const titles = new Set<string>();
  for (let index = 0; index < chapters.value.length; index += 1) {
    const chapter = chapters.value[index];
    if (!chapter?.title.trim()) return `第 ${index + 1} 个章节缺少标题`;
    if (!chapter.content.trim()) return `“${chapter.title}”缺少正文`;
    const key = chapter.title.trim().toLocaleLowerCase();
    if (titles.has(key)) return `章节标题重复：“${chapter.title}”`;
    titles.add(key);
  }
  return '';
}

function validateSubmission(): EditorIssue | null {
  const metadataIssue = validateMetadataSubmission();
  if (metadataIssue) return metadataIssue;
  if (!isPublished.value) {
    const chapterIssue = validateEditableChapters(true);
    return chapterIssue ? { message: chapterIssue, section: 'chapters' } : null;
  }
  if (!metadataHasChanges.value && reviewableChapterCount.value === 0) {
    return {
      message: metadataPending.value
        ? '作品资料正在审核，请等待审核结果或继续准备新的章节草稿'
        : '请先修改作品资料、已发布章节，或添加新的连载章节',
      section: 'footer',
    };
  }
  if (pendingSerialCount.value > 0 && reviewableChapterCount.value > 0) {
    return {
      message: '已有连载章节正在审核，请等待本批次完成后再提交新的章节变更',
      section: 'chapters',
    };
  }
  const chapterIssue = reviewableChapterCount.value > 0
    ? validateEditableChapters(false)
    : '';
  return chapterIssue ? { message: chapterIssue, section: 'chapters' } : null;
}

function validateMetadataSubmission(): EditorIssue | null {
  if (isPublished.value && !metadataHasChanges.value) return null;
  if (!form.title.trim() || form.title.trim() === '未命名作品') {
    return { message: '请填写明确的作品名称', section: 'metadata', field: 'title' };
  }
  if (!form.penName.trim()) {
    return { message: '请填写作者笔名', section: 'metadata', field: 'penName' };
  }
  if (!form.category.trim()) {
    return { message: '请选择作品分类', section: 'metadata', field: 'category' };
  }
  if (!form.coverUrl.trim()) {
    return { message: '请上传作品封面', section: 'metadata', field: 'cover' };
  }
  if (!form.description.trim()) {
    return { message: '请填写作品简介', section: 'metadata', field: 'description' };
  }
  return null;
}

async function presentEditorIssue(issue: EditorIssue): Promise<void> {
  editorIssue.value = issue;
  ElMessage.warning({ message: issue.message, duration: 5000, showClose: true });
  if (issue.section === 'footer') return;
  if (issue.section === 'metadata' && !openSections.value.includes('metadata')) {
    openSections.value = [...openSections.value, 'metadata'];
  }
  await nextTick();

  const container = issue.section === 'metadata'
    ? metadataSectionRef.value
    : chapterSectionRef.value;
  const selector = issue.field ? {
    title: '.field-title input',
    penName: '.field-pen-name input',
    category: '.field-category .el-select__wrapper',
    cover: '.cover-upload',
    description: '.field-description textarea',
  }[issue.field] : '';
  const target = selector ? container?.querySelector<HTMLElement>(selector) : null;
  (target || container)?.scrollIntoView?.({ behavior: 'smooth', block: 'center' });
  const focusable = target?.matches('input, textarea, [tabindex]')
    ? target
    : target?.querySelector<HTMLElement>('input, textarea, [tabindex]:not([tabindex="-1"])');
  focusable?.focus({ preventScroll: true });
}

function clearEditorIssue(section: EditorIssueSection): void {
  if (editorIssue.value?.section === section) editorIssue.value = null;
}

async function handleMutationError(error: unknown): Promise<void> {
  const message = errorMessage(error);
  editorIssue.value = { message, section: 'footer' };
  ElMessage.error(message);
  if (error instanceof ApiError && error.code === 'revision_conflict') {
    await loadDetail();
  }
}

async function beforeClose(done: () => void): Promise<void> {
  if (await confirmDiscard()) done();
}

async function requestClose(): Promise<void> {
  if (await confirmDiscard()) emit('update:modelValue', false);
}

async function confirmDiscard(): Promise<boolean> {
  if (!dirty.value || isPending.value) return true;
  try {
    await ElMessageBox.confirm('当前修改尚未保存，确定关闭吗？', '未保存的修改', {
      type: 'warning',
      confirmButtonText: '放弃修改',
      cancelButtonText: '继续编辑',
    });
    return true;
  } catch {
    return false;
  }
}

function serializeDraft(): string {
  return JSON.stringify({
    ...form,
    chapters: chapters.value.map((chapter) => ({
      id: chapter.id,
      publishedChapterId: chapter.publishedChapterId,
      title: chapter.title,
      content: chapter.content,
    })),
  });
}

function editableChapter(
  title: string,
  content: string,
  key: number | string,
  options: Partial<EditableChapter> = {},
): EditableChapter {
  return {
    clientId: `chapter-${key}-${Math.random().toString(36).slice(2, 8)}`,
    title,
    content,
    workflowStatus: 'draft',
    changeType: 'add',
    reviewNote: '',
    locked: false,
    ...options,
  };
}

function chapterToEditable(chapter: AiNovelChapter): EditableChapter {
  const isPublishedOriginal = chapter.status === 'published' && chapter.replacesChapterId == null;
  return editableChapter(chapter.title, chapter.content || '', chapter.id, {
    id: chapter.id,
    publishedChapterId: chapter.publishedChapterId,
    workflowStatus: chapter.status,
    changeType: chapter.changeType,
    reviewNote: chapter.reviewNote,
    originalTitle: chapter.originalTitle || (isPublishedOriginal ? chapter.title : ''),
    originalContent: chapter.originalContent || (isPublishedOriginal ? chapter.content || '' : ''),
    locked: chapter.status === 'pending',
  });
}

function mergePublishedChapters(source: AiNovelChapter[]): EditableChapter[] {
  const revisions = new Map(
    source
      .filter((chapter) => chapter.replacesChapterId != null)
      .map((chapter) => [chapter.replacesChapterId as number, chapter]),
  );
  const originals = source.filter(
    (chapter) => chapter.status === 'published' && chapter.replacesChapterId == null,
  );
  const mergedOriginals = originals.map((original) => {
    const revision = revisions.get(original.id);
    return editableChapter(
      revision?.title || original.title,
      revision?.content || original.content || '',
      revision?.id || original.id,
      {
        id: revision?.id || original.id,
        publishedChapterId: original.id,
        workflowStatus: revision?.status || 'published',
        changeType: revision ? 'update' : 'published',
        reviewNote: revision?.reviewNote || '',
        originalTitle: original.title,
        originalContent: original.content || '',
        locked: revision?.status === 'pending',
      },
    );
  });
  const additions = source
    .filter((chapter) => chapter.replacesChapterId == null && chapter.status !== 'published')
    .map(chapterToEditable);
  return [...mergedOriginals, ...additions];
}

function chapterChanged(chapter: EditableChapter): boolean {
  if (chapter.publishedChapterId == null) return true;
  return chapter.title !== (chapter.originalTitle || '')
    || chapter.content !== (chapter.originalContent || '');
}

function isChapterReviewable(chapter: EditableChapter): boolean {
  if (chapter.locked) return false;
  return chapter.publishedChapterId != null
    ? chapterChanged(chapter)
    : chapter.workflowStatus === 'draft' || chapter.workflowStatus === 'rejected';
}

function canMoveChapter(index: number, direction: -1 | 1): boolean {
  const target = index + direction;
  if (target < 0 || target >= chapters.value.length) return false;
  const current = chapters.value[index];
  const adjacent = chapters.value[target];
  if (!current || !adjacent || current.locked || adjacent.locked) return false;
  if (!isPublished.value) return true;
  return current.publishedChapterId == null && adjacent.publishedChapterId == null;
}

function chapterStateLabel(chapter: EditableChapter): string {
  if (chapter.publishedChapterId != null) {
    if (chapter.workflowStatus === 'pending') return '修改审核中';
    if (chapter.workflowStatus === 'rejected') return '修改被退回';
    if (chapterChanged(chapter)) return '待提交修改';
    return '已发布';
  }
  return {
    pending: '新增审核中',
    rejected: '新增被退回',
    draft: '待提交新增',
    published: '已发布',
  }[chapter.workflowStatus || 'draft'];
}

function chapterStateType(chapter: EditableChapter): 'info' | 'warning' | 'success' | 'danger' {
  if (chapter.workflowStatus === 'pending') return 'warning';
  if (chapter.workflowStatus === 'rejected') return 'danger';
  if (chapter.publishedChapterId != null && !chapterChanged(chapter)) return 'success';
  return 'info';
}

function statusLabel(value: string): string {
  return { draft: '草稿', pending: '审核中', published: '已发布', rejected: '需修改' }[value] || value;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '操作失败，请稍后重试';
}

function asUploadError(error: unknown): UploadAjaxError {
  const uploadError = (error instanceof Error ? error : new Error('文件处理失败')) as UploadAjaxError;
  uploadError.status ||= 0;
  uploadError.method ||= 'POST';
  uploadError.url ||= '';
  return uploadError;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="novel-editor-drawer"
    size="min(1120px, 96vw)"
    :before-close="beforeClose"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <div>
          <span class="eyebrow">CREATOR WORKSPACE</span>
          <h2>{{ isPublished ? '管理已发布作品' : '编辑 AI 小说' }}</h2>
        </div>
        <ElTag v-if="detail" :type="status === 'rejected' ? 'danger' : status === 'published' ? 'success' : status === 'pending' ? 'warning' : 'info'">
          {{ statusLabel(status) }} · R{{ detail.item.revision }}
        </ElTag>
      </div>
    </template>

    <div v-loading="loading" class="editor-body">
      <template v-if="detail">
        <ElAlert
          v-if="status === 'rejected'"
          type="error"
          :closable="false"
          show-icon
          title="审核未通过"
          :description="detail.item.reviewNote || '请根据审核意见修改后重新提交。'"
        />
        <ElAlert
          v-else-if="isPending"
          type="warning"
          :closable="false"
          show-icon
          title="作品正在审核"
          description="审核完成前内容已锁定；你仍可在下方查看本次提交的完整正文。"
        />
        <ElAlert
          v-if="isPublished && rejectedChapterSummary"
          type="error"
          :closable="false"
          show-icon
          title="有连载章节需要修改"
          :description="rejectedChapterSummary"
        />
        <ElAlert
          v-if="isPublished && metadataRevision?.status === 'rejected'"
          type="error"
          :closable="false"
          show-icon
          title="作品资料修改被退回"
          :description="metadataRevision.reviewNote || '请根据审核意见修改资料后重新提交。'"
        />
        <ElAlert
          v-if="isPublished && metadataPending"
          type="warning"
          :closable="false"
          show-icon
          title="作品资料正在审核"
          description="标题、简介、封面和连载状态会继续展示当前线上版本，审核通过后才替换。"
        />
        <ElAlert
          v-if="isPublished && pendingSerialCount > 0"
          type="warning"
          :closable="false"
          show-icon
          :title="`${pendingSerialCount} 个连载章节正在审核`"
          description="你可以继续准备草稿，但需要等待当前批次审核完成后再提交。"
        />
        <ElAlert
          v-if="isPublished && !rejectedChapterSummary && pendingSerialCount === 0 && !metadataPending"
          type="success"
           :closable="false"
           show-icon
           :title="`作品已发布 ${publishedChapterCount} 章`"
           description="线上版本保持可读；作品资料、章节修改和新增内容均需审核通过后才会在 App 生效。"
        />

        <div ref="metadataSectionRef">
          <ElCollapse v-model="openSections" class="editor-collapse">
            <ElCollapseItem name="metadata" title="作品资料与封面">
            <p v-if="isPublished && metadataChangeLabel" class="metadata-change-state">
              {{ metadataChangeLabel }}。线上资料会在审核通过后统一更新。
            </p>
            <div class="metadata-grid">
              <div class="cover-column">
                <ElUpload
                  class="cover-upload"
                  accept="image/jpeg,image/png,image/webp"
                  :show-file-list="false"
                  :http-request="handleCoverUpload"
                  :disabled="metadataLocked || uploadingCover"
                >
                  <div v-loading="uploadingCover" class="cover-frame">
                    <img v-if="form.coverUrl" :src="form.coverUrl" alt="作品封面预览">
                    <div v-else class="cover-empty">
                      <ElIcon :size="28"><UploadFilled /></ElIcon>
                      <strong>上传封面</strong>
                      <span>JPG / PNG / WebP，最大 5MB</span>
                    </div>
                    <span v-if="form.coverUrl && !metadataLocked" class="cover-change">点击更换封面</span>
                  </div>
                </ElUpload>
                <p class="field-help">封面由系统托管，不再要求填写图片 URL。</p>
                <p v-if="editorIssue?.field === 'cover'" class="field-error" role="alert">
                  {{ editorIssue.message }}
                </p>
              </div>

              <ElForm label-position="top" class="metadata-form">
                <div class="form-row two-columns">
                  <ElFormItem
                    class="field-title"
                    label="作品名称"
                    required
                    :error="editorIssue?.field === 'title' ? editorIssue.message : ''"
                  >
                    <ElInput v-model="form.title" :disabled="metadataLocked" maxlength="100" show-word-limit />
                 </ElFormItem>
                 <ElFormItem label="连载状态">
                   <ElSegmented
                     v-model="form.serializationStatus"
                  :disabled="metadataLocked"
                     :options="[
                       { label: '连载中', value: 'ongoing' },
                       { label: '已完结', value: 'completed' },
                     ]"
                   />
                 </ElFormItem>
                 <ElFormItem
                    class="field-pen-name"
                    label="作者笔名"
                    required
                    :error="editorIssue?.field === 'penName' ? editorIssue.message : ''"
                  >
                    <ElInput v-model="form.penName" :disabled="metadataLocked" maxlength="50" />
                  </ElFormItem>
                </div>
                <ElFormItem
                  class="field-category"
                  label="作品分类"
                  required
                  :error="editorIssue?.field === 'category' ? editorIssue.message : ''"
                >
                  <ElSelect
                    v-model="form.category"
                    :disabled="metadataLocked"
                    filterable
                    allow-create
                    default-first-option
                    placeholder="选择或创建分类"
                  >
                    <ElOption v-for="category in categories" :key="category" :label="category" :value="category" />
                  </ElSelect>
                </ElFormItem>
                <ElFormItem
                  class="field-description"
                  label="作品简介"
                  required
                  :error="editorIssue?.field === 'description' ? editorIssue.message : ''"
                >
                  <ElInput
                    v-model="form.description"
                    :disabled="metadataLocked"
                    type="textarea"
                    :rows="5"
                    maxlength="2000"
                    show-word-limit
                    placeholder="说明故事题材、核心冲突和看点"
                  />
                </ElFormItem>
              </ElForm>
            </div>
            </ElCollapseItem>
          </ElCollapse>
        </div>

        <section ref="chapterSectionRef" class="chapter-workspace">
          <header class="workspace-heading">
            <div>
              <span class="eyebrow">CHAPTERS</span>
               <h3>{{ isPending ? '提交内容预览' : isPublished ? '已发布章节与本次变更' : '正文拆章与预览' }}</h3>
               <p v-if="!isPending">{{ chapters.length }} 章 · {{ characterCount.toLocaleString() }} 字符</p>
            </div>
            <div v-if="!isPending" class="workspace-actions">
              <ElButton :icon="Plus" @click="addChapter">添加章节</ElButton>
            </div>
          </header>

          <ElUpload
            v-if="!isPending"
            ref="novelUploadRef"
            drag
            multiple
            class="novel-file-upload"
            accept=".txt,.md,text/plain,text/markdown"
            :show-file-list="false"
            :auto-upload="false"
            :limit="maxNovelChapterCount"
            :disabled="importing"
            :on-change="handleNovelFileSelection"
            :on-exceed="handleNovelImportExceed"
          >
            <ElIcon class="el-icon--upload"><DocumentAdd /></ElIcon>
            <div class="el-upload__text">
              <strong>拖入整书文件，或批量选择章节文件</strong>
            </div>
            <template #tip>
              <div class="el-upload__tip">
                单个文件自动拆章；多文件按文件名中的数字顺序排列，每个文件作为一章。支持 UTF-8、UTF-16 和 GB18030。
              </div>
            </template>
          </ElUpload>
          <ElAlert v-if="importSummary" class="import-summary" type="success" :closable="false" :title="importSummary" show-icon />

          <div v-if="visibleChapters.length" class="chapter-editor">
            <aside class="chapter-list">
               <button
                 v-for="(chapter, index) in visibleChapters"
                :key="chapter.clientId"
                type="button"
                :class="{ active: chapter.clientId === activeChapter?.clientId }"
                @click="selectedChapterId = chapter.clientId"
               >
                 <span>{{ index + 1 }}</span>
                 <span class="chapter-list-copy">
                   <strong>{{ chapter.title || '未命名章节' }}</strong>
                   <small>{{ chapter.content.length.toLocaleString() }} 字</small>
                 </span>
                 <ElTag
                   v-if="isPublished"
                   size="small"
                   effect="plain"
                   :type="chapterStateType(chapter)"
                 >{{ chapterStateLabel(chapter) }}</ElTag>
               </button>
            </aside>

            <div v-if="activeChapter" class="chapter-content-editor">
               <div v-if="!isPending" class="chapter-order-actions">
                 <ElTag
                   size="small"
                   effect="plain"
                   :type="chapterStateType(activeChapter)"
                 >{{ chapterStateLabel(activeChapter) }}</ElTag>
                 <ElButton
                   text
                   :icon="ArrowUp"
                   :disabled="!canMoveChapter(chapters.indexOf(activeChapter), -1)"
                   @click="moveChapter(chapters.indexOf(activeChapter), -1)"
                 >上移</ElButton>
                <ElButton
                   text
                   :icon="ArrowDown"
                   :disabled="!canMoveChapter(chapters.indexOf(activeChapter), 1)"
                   @click="moveChapter(chapters.indexOf(activeChapter), 1)"
                 >下移</ElButton>
                 <ElPopconfirm
                   v-if="!activeChapterLocked && (activeChapter.publishedChapterId == null || chapterChanged(activeChapter))"
                   :title="activeChapter.publishedChapterId != null ? '撤销这个章节的全部修改？' : '删除这个待新增章节？'"
                   :confirm-button-text="activeChapter.publishedChapterId != null ? '撤销修改' : '删除'"
                   cancel-button-text="取消"
                   @confirm="removeChapter(chapters.indexOf(activeChapter))"
                 >
                   <template #reference>
                     <ElButton text type="danger" :icon="Delete">
                       {{ activeChapter.publishedChapterId != null ? '撤销修改' : '删除' }}
                     </ElButton>
                   </template>
                 </ElPopconfirm>
               </div>
               <ElAlert
                 v-if="activeChapter.workflowStatus === 'rejected'"
                 class="chapter-status-alert"
                 type="error"
                 :closable="false"
                 show-icon
                 title="本次章节变更被退回"
                 :description="activeChapter.reviewNote || '请根据审核意见修改后重新提交。'"
               />
               <ElAlert
                 v-else-if="activeChapterLocked && isPublished"
                 class="chapter-status-alert"
                 type="warning"
                 :closable="false"
                 show-icon
                 title="该章节变更正在审核"
                 description="当前提交内容已锁定，线上版本会继续正常展示。"
               />
               <ElCollapse
                 v-if="activeChapter.publishedChapterId != null && chapterChanged(activeChapter)"
                 v-model="comparisonOpen"
                 class="online-version-collapse"
               >
                 <ElCollapseItem name="online-version" title="对照当前线上版本">
                   <strong>{{ activeChapter.originalTitle }}</strong>
                   <article>{{ activeChapter.originalContent }}</article>
                 </ElCollapseItem>
               </ElCollapse>
               <ElInput
                v-model="activeChapter.title"
                class="chapter-title-input"
                 :disabled="activeChapterLocked"
                maxlength="120"
                placeholder="章节标题"
                @input="clearEditorIssue('chapters')"
              />
              <ElInput
                v-model="activeChapter.content"
                class="chapter-body-input"
                 :disabled="activeChapterLocked"
                type="textarea"
                :autosize="{ minRows: 18, maxRows: 32 }"
                placeholder="章节正文"
                @input="clearEditorIssue('chapters')"
              />
            </div>
          </div>
           <ElEmpty v-else :description="isPublished ? '还没有已发布或待新增章节' : '导入文件或手动添加第一个章节'">
            <ElButton v-if="!isPending" type="primary" :icon="Plus" @click="addChapter">添加章节</ElButton>
          </ElEmpty>
        </section>
      </template>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <span v-if="editorIssue" class="action-error" role="alert">
          <ElIcon><WarningFilled /></ElIcon>
          {{ editorIssue.message }}
        </span>
        <span v-else-if="dirty" class="unsaved-indicator">有未保存修改</span>
         <span v-else-if="detail && !isPending" class="saved-indicator">内容已保存</span>
        <ElButton @click="requestClose">关闭</ElButton>
        <ElButton
          v-if="detail && !isPending"
          :loading="saving"
          :disabled="submitting"
          @click="saveDraft()"
        >保存草稿</ElButton>
        <ElButton
          v-if="detail && !isPending"
          type="primary"
          :loading="submitting"
          :disabled="saving || submitting"
          @click="submitForReview"
         >{{ submissionLabel }}</ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading,
.workspace-heading,
.drawer-footer,
.workspace-actions,
.chapter-order-actions {
  display: flex;
  align-items: center;
}

.drawer-heading,
.workspace-heading {
  justify-content: space-between;
  gap: 20px;
}

.drawer-heading h2,
.workspace-heading h3,
.workspace-heading p {
  margin: 0;
}

.drawer-heading h2 {
  margin-top: 4px;
  font-size: 20px;
}

.editor-body {
  min-height: 360px;
  display: grid;
  gap: 18px;
}

.editor-collapse {
  border: 1px solid var(--line);
  border-radius: 16px;
  padding: 0 18px;
  background: var(--surface);
}

.metadata-grid {
  display: grid;
  grid-template-columns: 180px minmax(0, 1fr);
  gap: 26px;
  padding: 6px 2px 18px;
}

.metadata-change-state {
  margin: 8px 2px 14px;
  color: var(--ink-500);
  font-size: 12px;
  line-height: 1.6;
}

.cover-frame {
  position: relative;
  width: 164px;
  aspect-ratio: 3 / 4;
  overflow: hidden;
  display: grid;
  place-items: center;
  border: 1px dashed #d8cbd2;
  border-radius: 14px;
  color: var(--ink-500);
  background: var(--surface-muted);
}

.cover-frame img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}

.cover-empty {
  display: grid;
  place-items: center;
  gap: 8px;
  padding: 18px;
  text-align: center;
}

.cover-empty span,
.field-help {
  color: var(--ink-500);
  font-size: 12px;
  line-height: 1.6;
}

.cover-change {
  position: absolute;
  inset: auto 0 0;
  padding: 9px;
  color: white;
  background: rgb(37 36 42 / 72%);
  font-size: 12px;
  text-align: center;
}

.field-help {
  margin: 8px 4px 0;
}

.field-error {
  margin: 6px 4px 0;
  color: var(--el-color-danger);
  font-size: 12px;
  line-height: 1.4;
}

.form-row.two-columns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}

.metadata-form :deep(.el-select) {
  width: 100%;
}

.metadata-form :deep(.el-segmented) {
  width: min(320px, 100%);
}

.chapter-workspace {
  display: grid;
  gap: 16px;
  padding: 20px;
  border: 1px solid var(--line);
  border-radius: 18px;
  background: var(--surface);
}

.workspace-heading p {
  margin-top: 5px;
  color: var(--ink-500);
  font-size: 13px;
}

.novel-file-upload :deep(.el-upload-dragger) {
  padding: 20px;
  border-radius: 14px;
  background: var(--sakura-50);
}

.novel-file-upload :deep(.el-icon--upload) {
  margin-bottom: 8px;
  color: var(--sakura-500);
  font-size: 34px;
}

.import-summary {
  margin-top: -4px;
}

.chapter-editor {
  min-height: 520px;
  display: grid;
  grid-template-columns: 310px minmax(0, 1fr);
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 14px;
}

.chapter-list {
  max-height: 660px;
  overflow: auto;
  padding: 8px;
  border-right: 1px solid var(--line);
  background: var(--surface-muted);
}

.chapter-list button {
  width: 100%;
  display: grid;
  grid-template-columns: 28px minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
  border: 0;
  border-radius: 10px;
  padding: 10px 8px;
  color: var(--ink-700);
  background: transparent;
  text-align: left;
}

.chapter-list button:hover,
.chapter-list button.active {
  color: var(--sakura-600);
  background: white;
}

.chapter-list button > span:first-child {
  width: 26px;
  height: 26px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  background: var(--sakura-100);
  font-size: 12px;
}

.chapter-list-copy {
  min-width: 0;
  display: grid;
  gap: 3px;
}

.chapter-list strong {
  overflow: hidden;
  font-size: 13px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.chapter-list small {
  color: var(--ink-300);
  font-size: 10px;
}

.chapter-list :deep(.el-tag) {
  max-width: 76px;
  overflow: hidden;
  text-overflow: ellipsis;
}

.chapter-content-editor {
  min-width: 0;
  padding: 18px;
}

.chapter-order-actions {
  justify-content: flex-end;
  margin-bottom: 10px;
}

.chapter-order-actions > :deep(.el-tag) {
  margin-right: auto;
}

.chapter-status-alert,
.online-version-collapse {
  margin-bottom: 12px;
}

.online-version-collapse {
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 0 12px;
  background: var(--surface-muted);
}

.online-version-collapse article {
  max-height: 240px;
  overflow: auto;
  margin-top: 10px;
  color: var(--ink-500);
  font-size: 13px;
  line-height: 1.8;
  white-space: pre-wrap;
}

.chapter-title-input {
  margin-bottom: 12px;
}

.chapter-title-input :deep(.el-input__wrapper) {
  box-shadow: none;
  border-bottom: 1px solid var(--line);
  border-radius: 0;
  padding-inline: 2px;
  font-size: 18px;
  font-weight: 700;
}

.chapter-body-input :deep(.el-textarea__inner) {
  border: 0;
  box-shadow: none;
  padding: 12px 2px;
  font-size: 15px;
  line-height: 1.9;
}

.drawer-footer {
  justify-content: flex-end;
  gap: 10px;
}

.unsaved-indicator,
.saved-indicator,
.action-error {
  margin-right: auto;
  font-size: 12px;
}

.unsaved-indicator { color: #c87825; }
.saved-indicator { color: #4c936f; }

.action-error {
  max-width: min(520px, 58%);
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--el-color-danger);
  line-height: 1.45;
}

@media (max-width: 760px) {
  .metadata-grid,
  .form-row.two-columns,
  .chapter-editor {
    grid-template-columns: 1fr;
  }

  .cover-column {
    display: grid;
    justify-items: center;
  }

  .chapter-list {
    max-height: 210px;
    border-right: 0;
    border-bottom: 1px solid var(--line);
  }

  .chapter-editor {
    min-height: 0;
  }

  .workspace-heading,
  .drawer-footer {
    align-items: flex-start;
    flex-wrap: wrap;
  }

  .unsaved-indicator,
  .saved-indicator,
  .action-error {
    width: 100%;
    max-width: none;
  }
}
</style>
