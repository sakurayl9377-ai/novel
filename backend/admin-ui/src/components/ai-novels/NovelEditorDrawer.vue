<script setup lang="ts">
import {
  ArrowDown,
  ArrowUp,
  Delete,
  DocumentAdd,
  Plus,
  UploadFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import type { UploadRequestOptions } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  getCreatorNovel,
  saveNovelDraft,
  submitNovel,
  uploadNovelCover,
} from '@/services/ai-novels';
import type { AiNovelDetail, EditableChapter } from '@/types/ai-novel';
import { decodeNovelFile, parseNovelText } from '@/utils/novel-import';

type UploadAjaxError = Parameters<UploadRequestOptions['onError']>[0];

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
const chapters = ref<EditableChapter[]>([]);
const previewChapters = ref<EditableChapter[]>([]);
const selectedChapterId = ref('');
const savedSnapshot = ref('');

const form = reactive({
  title: '',
  penName: '',
  category: 'AI原创',
  coverUrl: '',
  description: '',
});

const status = computed(() => detail.value?.item.status || 'draft');
const isPending = computed(() => status.value === 'pending');
const isPublished = computed(() => status.value === 'published');
const metadataLocked = computed(() => isPending.value || isPublished.value);
const visibleChapters = computed(() => isPending.value ? previewChapters.value : chapters.value);
const activeChapter = computed(() =>
  visibleChapters.value.find((chapter) => chapter.clientId === selectedChapterId.value)
  || visibleChapters.value[0]
  || null,
);
const characterCount = computed(() => chapters.value.reduce(
  (total, chapter) => total + chapter.title.length + chapter.content.length,
  0,
));
const publishedChapterCount = computed(() =>
  detail.value?.chapters.filter((chapter) => chapter.status === 'published').length || 0,
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
const dirty = computed(() => Boolean(detail.value) && serializeDraft() !== savedSnapshot.value);
const canSubmit = computed(() =>
  !isPending.value && chapters.value.length > 0 && pendingSerialCount.value === 0,
);

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
  Object.assign(form, {
    title: data.item.title,
    penName: data.item.author,
    category: data.item.category,
    coverUrl: data.item.coverUrl,
    description: data.item.description,
  });
  chapters.value = data.chapters
    .filter((chapter) => chapter.status === 'draft' || chapter.status === 'rejected')
    .map((chapter) => editableChapter(chapter.title, chapter.content || '', chapter.id));
  previewChapters.value = data.chapters.map((chapter) =>
    editableChapter(chapter.title, chapter.content || '', chapter.id),
  );
  selectedChapterId.value = (isPending.value ? previewChapters.value[0] : chapters.value[0])?.clientId || '';
  importSummary.value = '';
  savedSnapshot.value = serializeDraft();
}

async function saveDraft(showMessage = true): Promise<AiNovelDetail | null> {
  if (!props.novelId || !detail.value || isPending.value) return null;
  const issue = validateEditableChapters(false);
  if (issue) {
    ElMessage.warning(issue);
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
      chapters: chapters.value.map(({ title, content }) => ({ title, content })),
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
    ElMessage.warning(issue);
    return;
  }
  submitting.value = true;
  try {
    const saved = await saveDraft(false);
    if (!saved) return;
    const submitted = await submitNovel(props.novelId, saved.item.revision);
    applyDetail(submitted);
    emit('saved');
    ElMessage.success(isPublished.value ? '新增章节已提交审核' : '作品已提交审核');
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

async function handleNovelImport(options: UploadRequestOptions): Promise<void> {
  importing.value = true;
  try {
    const extension = options.file.name.split('.').pop()?.toLowerCase();
    if (!['txt', 'md'].includes(extension || '')) {
      throw new Error('仅支持 TXT 或 Markdown 文件');
    }
    const decoded = await decodeNovelFile(options.file);
    const parsed = parseNovelText(decoded.text);
    if (chapters.value.length) {
      await ElMessageBox.confirm(
        `导入将替换当前 ${chapters.value.length} 个未提交章节，是否继续？`,
        '替换章节',
        { type: 'warning', confirmButtonText: '继续导入', cancelButtonText: '取消' },
      );
    }
    chapters.value = parsed.chapters;
    selectedChapterId.value = chapters.value[0]?.clientId || '';
    importSummary.value = `${options.file.name} · ${decoded.encoding} · ${parsed.chapters.length} 章 · ${parsed.characterCount.toLocaleString()} 字符`;
    if (form.title === '未命名作品') {
      form.title = options.file.name.replace(/\.(?:txt|md)$/i, '');
    }
    options.onSuccess(parsed);
    ElMessage.success(`已识别 ${parsed.chapters.length} 个章节，请预览后保存`);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    if (reason !== 'cancel' && reason !== 'close') {
      options.onError(asUploadError(error));
      ElMessage.error(errorMessage(error));
    }
  } finally {
    importing.value = false;
  }
}

function addChapter(): void {
  const chapter = editableChapter(`第 ${chapters.value.length + 1} 章`, '', Date.now());
  chapters.value.push(chapter);
  selectedChapterId.value = chapter.clientId;
}

function removeChapter(index: number): void {
  chapters.value.splice(index, 1);
  selectedChapterId.value = chapters.value[Math.min(index, chapters.value.length - 1)]?.clientId || '';
}

function moveChapter(index: number, direction: -1 | 1): void {
  const target = index + direction;
  if (target < 0 || target >= chapters.value.length) return;
  const [chapter] = chapters.value.splice(index, 1);
  if (!chapter) return;
  chapters.value.splice(target, 0, chapter);
}

function validateEditableChapters(requireOne: boolean): string {
  if (requireOne && !chapters.value.length) {
    return isPublished.value ? '请先添加需要连载的新章节' : '请先导入或添加正文章节';
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

function validateSubmission(): string {
  if (!form.title.trim() || form.title.trim() === '未命名作品') return '请填写明确的作品名称';
  if (!form.penName.trim()) return '请填写作者笔名';
  if (!form.category.trim()) return '请选择作品分类';
  if (!form.coverUrl) return '请上传作品封面';
  if (!form.description.trim()) return '请填写作品简介';
  return validateEditableChapters(true);
}

async function handleMutationError(error: unknown): Promise<void> {
  ElMessage.error(errorMessage(error));
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
  return JSON.stringify({ ...form, chapters: chapters.value.map(({ title, content }) => ({ title, content })) });
}

function editableChapter(title: string, content: string, id: number): EditableChapter {
  return {
    clientId: `chapter-${id}-${Math.random().toString(36).slice(2, 8)}`,
    title,
    content,
  };
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
          <h2>{{ isPublished ? '管理连载章节' : '编辑 AI 小说' }}</h2>
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
          v-if="isPublished && pendingSerialCount > 0"
          type="warning"
          :closable="false"
          show-icon
          :title="`${pendingSerialCount} 个连载章节正在审核`"
          description="你可以继续准备草稿，但需要等待当前批次审核完成后再提交。"
        />
        <ElAlert
          v-if="isPublished && !rejectedChapterSummary && pendingSerialCount === 0"
          type="success"
          :closable="false"
          show-icon
          :title="`作品已发布 ${publishedChapterCount} 章`"
          description="作品资料和已发布章节保持不变；下方仅编辑本次准备追加的连载章节。"
        />

        <ElCollapse v-model="openSections" class="editor-collapse">
          <ElCollapseItem name="metadata" title="作品资料与封面">
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
              </div>

              <ElForm label-position="top" class="metadata-form">
                <div class="form-row two-columns">
                  <ElFormItem label="作品名称" required>
                    <ElInput v-model="form.title" :disabled="metadataLocked" maxlength="100" show-word-limit />
                  </ElFormItem>
                  <ElFormItem label="作者笔名" required>
                    <ElInput v-model="form.penName" :disabled="metadataLocked" maxlength="50" />
                  </ElFormItem>
                </div>
                <ElFormItem label="作品分类" required>
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
                <ElFormItem label="作品简介" required>
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

        <section class="chapter-workspace">
          <header class="workspace-heading">
            <div>
              <span class="eyebrow">CHAPTERS</span>
              <h3>{{ isPending ? '提交内容预览' : isPublished ? '新增连载章节' : '正文拆章与预览' }}</h3>
              <p v-if="!isPending">{{ chapters.length }} 章 · {{ characterCount.toLocaleString() }} 字符</p>
            </div>
            <div v-if="!isPending" class="workspace-actions">
              <ElButton :icon="Plus" @click="addChapter">添加章节</ElButton>
            </div>
          </header>

          <ElUpload
            v-if="!isPending"
            drag
            class="novel-file-upload"
            accept=".txt,.md,text/plain,text/markdown"
            :show-file-list="false"
            :http-request="handleNovelImport"
            :disabled="importing"
          >
            <ElIcon class="el-icon--upload"><DocumentAdd /></ElIcon>
            <div class="el-upload__text"><strong>拖入 TXT / Markdown</strong>，或点击选择文件</div>
            <template #tip>
              <div class="el-upload__tip">
                自动识别 UTF-8、UTF-16 和 GB18030；导入后先预览拆章，不会直接提交。
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
                <strong>{{ chapter.title || '未命名章节' }}</strong>
                <small>{{ chapter.content.length.toLocaleString() }} 字</small>
              </button>
            </aside>

            <div v-if="activeChapter" class="chapter-content-editor">
              <div v-if="!isPending" class="chapter-order-actions">
                <ElButton
                  text
                  :icon="ArrowUp"
                  :disabled="chapters.indexOf(activeChapter) <= 0"
                  @click="moveChapter(chapters.indexOf(activeChapter), -1)"
                >上移</ElButton>
                <ElButton
                  text
                  :icon="ArrowDown"
                  :disabled="chapters.indexOf(activeChapter) >= chapters.length - 1"
                  @click="moveChapter(chapters.indexOf(activeChapter), 1)"
                >下移</ElButton>
                <ElPopconfirm
                  title="删除这个章节？"
                  confirm-button-text="删除"
                  cancel-button-text="取消"
                  @confirm="removeChapter(chapters.indexOf(activeChapter))"
                >
                  <template #reference>
                    <ElButton text type="danger" :icon="Delete">删除</ElButton>
                  </template>
                </ElPopconfirm>
              </div>
              <ElInput
                v-model="activeChapter.title"
                class="chapter-title-input"
                :disabled="isPending"
                maxlength="120"
                placeholder="章节标题"
              />
              <ElInput
                v-model="activeChapter.content"
                class="chapter-body-input"
                :disabled="isPending"
                type="textarea"
                :autosize="{ minRows: 18, maxRows: 32 }"
                placeholder="章节正文"
              />
            </div>
          </div>
          <ElEmpty v-else :description="isPublished ? '还没有待追加的章节' : '导入文件或手动添加第一个章节'">
            <ElButton v-if="!isPending" type="primary" :icon="Plus" @click="addChapter">添加章节</ElButton>
          </ElEmpty>
        </section>
      </template>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <span v-if="dirty" class="unsaved-indicator">有未保存修改</span>
        <span v-else-if="detail && !isPending" class="saved-indicator">草稿已保存</span>
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
          :disabled="saving || !canSubmit"
          @click="submitForReview"
        >{{ isPublished ? '提交新增章节' : status === 'rejected' ? '修改并重新提交' : '提交审核' }}</ElButton>
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

.form-row.two-columns {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}

.metadata-form :deep(.el-select) {
  width: 100%;
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
  grid-template-columns: 260px minmax(0, 1fr);
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

.chapter-list button > span {
  width: 26px;
  height: 26px;
  display: grid;
  place-items: center;
  border-radius: 8px;
  background: var(--sakura-100);
  font-size: 12px;
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

.chapter-content-editor {
  min-width: 0;
  padding: 18px;
}

.chapter-order-actions {
  justify-content: flex-end;
  margin-bottom: 10px;
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
.saved-indicator {
  margin-right: auto;
  font-size: 12px;
}

.unsaved-indicator { color: #c87825; }
.saved-indicator { color: #4c936f; }

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
  .saved-indicator {
    width: 100%;
  }
}
</style>
