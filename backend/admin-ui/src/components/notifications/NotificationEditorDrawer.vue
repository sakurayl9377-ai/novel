<script setup lang="ts">
import { Bell, InfoFilled, Promotion, Refresh, User } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import {
  createNotification,
  previewNotification,
  updateNotification,
} from '@/services/notifications';
import type {
  NotificationAudienceScope,
  NotificationCategory,
  NotificationDetailResponse,
  NotificationItem,
  NotificationOptions,
  NotificationPreview,
} from '@/types/notifications';
import { formatDateTime } from '@/utils/format';
import {
  notificationAudienceLabel,
  notificationCategoryLabel,
  notificationFormError,
} from '@/utils/notifications';

const props = defineProps<{
  modelValue: boolean;
  item: NotificationItem | null;
  options: NotificationOptions;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: NotificationDetailResponse, reviewSend: boolean];
  reload: [];
}>();

const saving = ref(false);
const previewing = ref(false);
const preview = ref<NotificationPreview | null>(null);
const openSections = ref(['content', 'audience', 'preview']);
const form = reactive({
  title: '',
  content: '',
  category: 'system' as NotificationCategory,
  scope: 'all_active' as NotificationAudienceScope,
  recentDays: 7,
  platforms: [] as string[],
  minVersionCode: 0,
  maxVersionCode: 0,
  includeAdmins: false,
  changeNote: '',
});

const editing = computed(() => Boolean(props.item));
const audience = computed(() => ({
  scope: form.scope,
  recentDays: form.scope === 'recent_active' ? form.recentDays : 0,
  platforms: form.platforms,
  minVersionCode: form.minVersionCode,
  maxVersionCode: form.maxVersionCode,
  includeAdmins: form.includeAdmins,
}));
const audienceLabel = computed(() => notificationAudienceLabel(audience.value));
const categoryOptions = computed(() => props.options.categories.length
  ? props.options.categories
  : ['system', 'update', 'operation', 'security'] as NotificationCategory[]);
const platformOptions = computed(() => props.options.platforms.length
  ? props.options.platforms
  : ['android', 'ios', 'windows', 'macos', 'web']);

watch(
  () => props.modelValue,
  (open) => {
    if (open) resetForm();
  },
);

function resetForm(): void {
  const source = props.item;
  const sourceAudience = source?.audience;
  Object.assign(form, {
    title: source?.title || '',
    content: source?.content || '',
    category: source?.category || 'system',
    scope: sourceAudience?.scope || 'all_active',
    recentDays: sourceAudience?.recentDays || 7,
    platforms: [...(sourceAudience?.platforms || [])],
    minVersionCode: sourceAudience?.minVersionCode || 0,
    maxVersionCode: sourceAudience?.maxVersionCode || 0,
    includeAdmins: sourceAudience?.includeAdmins || false,
    changeNote: '',
  });
  preview.value = null;
  openSections.value = ['content', 'audience', 'preview'];
}

async function runPreview(): Promise<void> {
  const validation = notificationFormError({
    title: form.title,
    content: form.content,
    changeNote: 'preview',
    minVersionCode: form.minVersionCode,
    maxVersionCode: form.maxVersionCode,
    scope: form.scope,
    recentDays: form.recentDays,
  });
  if (validation && validation !== '请填写具体的创建或修改原因') {
    ElMessage.warning(validation);
    return;
  }
  previewing.value = true;
  try {
    preview.value = await previewNotification({
      title: form.title.trim(),
      content: form.content.trim(),
      category: form.category,
      audience: audience.value,
    });
  } catch (error) {
    ElMessage.error(errorMessage(error, '受众预览失败'));
  } finally {
    previewing.value = false;
  }
}

async function save(reviewSend = false): Promise<void> {
  const validation = notificationFormError({
    title: form.title,
    content: form.content,
    changeNote: form.changeNote,
    minVersionCode: form.minVersionCode,
    maxVersionCode: form.maxVersionCode,
    scope: form.scope,
    recentDays: form.recentDays,
  });
  if (validation) {
    ElMessage.warning(validation);
    return;
  }
  saving.value = true;
  try {
    const payload = {
      title: form.title.trim(),
      content: form.content.trim(),
      category: form.category,
      audience: audience.value,
      changeNote: form.changeNote.trim(),
    };
    const result = props.item
      ? await updateNotification(props.item.id, {
        ...payload,
        expectedRevision: props.item.revision,
      })
      : await createNotification(payload);
    ElMessage.success(reviewSend ? '草稿已保存，请检查受众后确认发送' : (props.item ? '通知草稿已更新' : '通知草稿已创建'));
    emit('saved', result, reviewSend);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '通知草稿保存失败'));
    emit('reload');
  } finally {
    saving.value = false;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(720px, 97vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="editor-heading">
        <span class="eyebrow">IN-APP MESSAGE DRAFT</span>
        <h2>{{ editing ? '编辑通知草稿' : '创建通知草稿' }}</h2>
        <p>{{ editing ? `修订号 ${item?.revision} · 修改后需要重新预览` : '保存后仍不会发送，确认受众后再执行发送' }}</p>
      </div>
    </template>

    <div class="notification-editor-body">
      <ElAlert
        type="info"
        :closable="false"
        show-icon
        title="投递位置：App 消息中心"
      >
        <template #default>这类通知会进入用户的“消息”页面，不会在 App 启动时弹窗。</template>
      </ElAlert>
      <ElCollapse v-model="openSections" class="editor-collapse">
        <ElCollapseItem name="content">
          <template #title>
            <span class="collapse-heading"><ElIcon><Bell /></ElIcon>消息内容</span>
          </template>
          <div class="form-grid">
            <ElFormItem label="通知类型" required>
              <ElSelect v-model="form.category" class="full-width" placeholder="选择通知类型">
                <ElOption
                  v-for="category in categoryOptions"
                  :key="category"
                  :label="notificationCategoryLabel(category)"
                  :value="category"
                />
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="标题" required>
              <ElInput v-model="form.title" maxlength="80" show-word-limit placeholder="用户在消息中心看到的标题" />
            </ElFormItem>
            <ElFormItem class="wide" label="正文" required>
              <ElInput
                v-model="form.content"
                type="textarea"
                :rows="7"
                maxlength="2000"
                show-word-limit
                placeholder="只支持纯文本，避免把 HTML 或外部链接直接注入用户消息"
              />
            </ElFormItem>
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="audience">
          <template #title>
            <span class="collapse-heading"><ElIcon><User /></ElIcon>受众条件</span>
          </template>
          <div class="audience-summary"><ElIcon><InfoFilled /></ElIcon><span>{{ audienceLabel }}</span></div>
          <div class="form-grid">
            <ElFormItem class="wide" label="基础人群" required>
              <ElSelect v-model="form.scope" class="full-width" placeholder="选择基础人群">
                <ElOption label="全部活跃普通用户" value="all_active" />
                <ElOption label="最近活跃用户" value="recent_active" />
              </ElSelect>
            </ElFormItem>
            <ElFormItem v-if="form.scope === 'recent_active'" label="活跃时间">
              <ElSelect v-model="form.recentDays" class="full-width">
                <ElOption v-for="days in (props.options.recentDays.length ? props.options.recentDays : [1, 7, 30])" :key="days" :label="`最近 ${days} 天`" :value="days" />
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="客户端平台">
              <ElSelect v-model="form.platforms" class="full-width" multiple collapse-tags collapse-tags-tooltip clearable placeholder="不限制平台">
                <ElOption v-for="platform in platformOptions" :key="platform" :label="platform" :value="platform" />
              </ElSelect>
            </ElFormItem>
            <ElFormItem label="最低版本号">
              <ElInputNumber v-model="form.minVersionCode" :min="0" :max="1000000000" controls-position="right" class="full-width" />
            </ElFormItem>
            <ElFormItem label="最高版本号">
              <ElInputNumber v-model="form.maxVersionCode" :min="0" :max="1000000000" controls-position="right" class="full-width" />
            </ElFormItem>
            <div class="wide admin-switch-row">
              <div><strong>包含管理员</strong><small>默认排除管理员和系统机器人，只有确有需要时才打开</small></div>
              <ElSwitch v-model="form.includeAdmins" active-text="包含" inactive-text="排除" />
            </div>
            <ElAlert v-if="form.includeAdmins" class="wide" type="warning" :closable="false" show-icon title="当前受众会包含活跃管理员，请发送前再次确认" />
          </div>
        </ElCollapseItem>

        <ElCollapseItem name="preview">
          <template #title>
            <span class="collapse-heading"><ElIcon><Promotion /></ElIcon>发送前预览</span>
          </template>
          <div class="preview-toolbar">
            <div><strong>实时受众估算</strong><small>发送时后端会再次计算，预览不会锁定人数</small></div>
            <ElButton :icon="Refresh" :loading="previewing" @click="runPreview">刷新预览</ElButton>
          </div>
          <div v-if="preview" class="preview-result">
            <div class="preview-count"><strong>{{ preview.eligibleCount.toLocaleString() }}</strong><span>位符合条件的用户</span></div>
            <ElTag v-if="preview.eligibleCount > preview.maxRecipients" type="danger" effect="plain">超过单次上限</ElTag>
            <ElTag v-else type="success" effect="plain">可以发送</ElTag>
            <div class="preview-sample">
              <span v-for="sample in preview.sample" :key="sample.id" class="sample-chip">
                {{ sample.nickname || `用户 #${sample.id}` }} · {{ sample.platform }} {{ sample.versionCode || '未上报版本' }}
              </span>
              <small v-if="preview.truncated">仅展示前 {{ preview.sample.length }} 位样本</small>
              <small v-if="!preview.sample.length">没有可展示的样本</small>
            </div>
          </div>
          <ElEmpty v-else :image-size="52" description="点击刷新预览，确认受众范围" />
        </ElCollapseItem>
      </ElCollapse>

      <div class="change-note-block">
        <ElFormItem label="变更原因" required>
          <ElInput v-model="form.changeNote" maxlength="500" show-word-limit placeholder="例如：发布 5.4.0 版本维护提醒" />
        </ElFormItem>
      </div>
    </div>

    <template #footer>
      <div class="drawer-footer">
        <span class="footer-hint">保存草稿不会向用户发送消息</span>
        <div class="footer-actions">
          <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
          <ElButton :loading="saving" @click="save(false)">仅保存草稿</ElButton>
          <ElButton type="primary" :icon="Promotion" :loading="saving" @click="save(true)">保存并检查发送</ElButton>
        </div>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.editor-heading { display: grid; gap: 5px; }
.editor-heading .eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.editor-heading h2 { margin: 0; color: var(--ink-900); font-size: 20px; }
.editor-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.notification-editor-body { display: grid; gap: 16px; }
.editor-collapse { border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.editor-collapse :deep(.el-collapse-item__header) { min-height: 56px; height: auto; padding: 8px 16px; }
.editor-collapse :deep(.el-collapse-item__content) { padding: 0 16px 16px; }
.collapse-heading { display: inline-flex; align-items: center; gap: 8px; color: var(--ink-900); font-size: 13px; font-weight: 700; }
.collapse-heading .el-icon { color: var(--sakura-600); }
.form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
.form-grid .wide { grid-column: 1 / -1; }
.full-width { width: 100%; }
.audience-summary { display: flex; align-items: center; gap: 7px; margin-bottom: 12px; padding: 10px 12px; border: 1px solid #ead6de; border-radius: 7px; color: var(--sakura-700); background: #fff8fa; font-size: 12px; }
.admin-switch-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 10px 0 13px; }
.admin-switch-row > div { display: grid; gap: 3px; }
.admin-switch-row strong { color: var(--ink-800); font-size: 12px; }
.admin-switch-row small { color: var(--ink-500); font-size: 10px; }
.preview-toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
.preview-toolbar > div { display: grid; gap: 3px; }
.preview-toolbar strong { color: var(--ink-900); font-size: 12px; }
.preview-toolbar small { color: var(--ink-500); font-size: 10px; }
.preview-result { display: grid; grid-template-columns: auto auto; align-items: center; gap: 10px 14px; padding: 14px; border: 1px solid #d9ebdf; border-radius: 8px; background: #f5fbf7; }
.preview-count { display: flex; align-items: baseline; gap: 7px; }
.preview-count strong { color: #267153; font-size: 25px; }
.preview-count span { color: #527466; font-size: 11px; }
.preview-sample { grid-column: 1 / -1; display: flex; flex-wrap: wrap; gap: 6px; }
.sample-chip { max-width: 100%; padding: 5px 8px; border-radius: 5px; color: #47655a; background: #e7f4eb; font-size: 10px; }
.preview-sample small { width: 100%; color: #719085; font-size: 10px; }
.change-note-block { padding: 13px 14px 2px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.drawer-footer { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.footer-hint { color: var(--ink-500); font-size: 10px; }
.footer-actions { display: flex; align-items: center; gap: 8px; }
@media (max-width: 620px) {
  .form-grid { grid-template-columns: 1fr; }
  .form-grid .wide { grid-column: auto; }
  .preview-result { grid-template-columns: 1fr; }
  .preview-sample { grid-column: auto; }
  .drawer-footer { align-items: flex-end; flex-direction: column; }
  .footer-actions { width: 100%; flex-wrap: wrap; justify-content: flex-end; }
}
</style>
