<script setup lang="ts">
import { Coin, Lock, Search, Tickets } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import {
  createGrowthCampaignTask,
  searchGrowthCatalog,
  updateGrowthCampaignTask,
} from '@/services/growth-operations';
import type {
  CampaignDetailResponse,
  CampaignTask,
  CatalogSearchItem,
  GrowthContentType,
} from '@/types/growth-operations';
import {
  growthContentTypeLabel,
  growthEventLabel,
  growthTaskSupportsContentScope,
  normalizeGrowthTaskTargetCount,
} from '@/utils/growth-operations';

const props = defineProps<{
  modelValue: boolean;
  detail: CampaignDetailResponse;
  task: CampaignTask | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: CampaignDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const searching = ref(false);
const catalog = ref<CatalogSearchItem[]>([]);
const form = reactive({
  taskKey: '',
  title: '',
  description: '',
  eventName: '',
  targetCount: 1,
  rewardPoints: 0,
  rewardCoins: 0,
  contentType: '' as GrowthContentType,
  contentKey: '',
  sortOrder: 0,
  status: 'active' as 'active' | 'disabled',
  changeNote: '',
});

const editing = computed(() => Boolean(props.task));
const identityLocked = computed(() => Boolean(props.task?.identityLocked));
const rewardLocked = computed(() => Boolean(props.task?.rewardLocked));
const loginEvent = computed(() => form.eventName === 'login');
const contentEvent = computed(() => growthTaskSupportsContentScope(form.eventName));

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    Object.assign(form, {
      taskKey: props.task?.taskKey || '',
      title: props.task?.title || '',
      description: props.task?.description || '',
      eventName: props.task?.eventName || 'start',
      targetCount: props.task?.targetCount || 1,
      rewardPoints: props.task?.rewardPoints || 0,
      rewardCoins: props.task?.rewardCoins || 0,
      contentType: props.task?.contentType || '',
      contentKey: props.task?.contentKey || '',
      sortOrder: props.task?.sortOrder || props.detail.tasks.length * 10,
      status: props.task?.status || 'active',
      changeNote: '',
    });
    catalog.value = [];
    if (form.contentKey) void searchCatalog(form.contentKey);
  },
);

watch(
  () => form.eventName,
  (eventName) => {
    if (eventName !== 'login') return;
    form.targetCount = 1;
    form.contentType = '';
    form.contentKey = '';
    catalog.value = [];
  },
);

watch(
  () => form.contentType,
  () => {
    if (!identityLocked.value) form.contentKey = '';
  },
);

async function searchCatalog(keyword: string): Promise<void> {
  searching.value = true;
  try {
    const response = await searchGrowthCatalog({
      q: keyword.trim(),
      type: form.contentType,
      status: 'active',
      page: 1,
      pageSize: 20,
    });
    catalog.value = response.items;
  } catch (error) {
    ElMessage.error(errorMessage(error, '内容目录搜索失败'));
  } finally {
    searching.value = false;
  }
}

async function save(): Promise<void> {
  const validation = validateForm();
  if (validation) {
    ElMessage.warning(validation);
    return;
  }
  saving.value = true;
  try {
    const payload = {
      expectedRevision: props.detail.item.revision,
      taskKey: form.taskKey.trim(),
      title: form.title.trim(),
      description: form.description.trim(),
      eventName: form.eventName,
      targetCount: normalizeGrowthTaskTargetCount(form.eventName, form.targetCount),
      rewardPoints: form.rewardPoints,
      rewardCoins: form.rewardCoins,
      contentType: contentEvent.value ? form.contentType : '' as GrowthContentType,
      contentKey: contentEvent.value ? form.contentKey : '',
      sortOrder: form.sortOrder,
      status: form.status,
      changeNote: form.changeNote.trim(),
    };
    const result = props.task
      ? await updateGrowthCampaignTask(props.detail.item.id, props.task.id, payload)
      : await createGrowthCampaignTask(props.detail.item.id, payload);
    ElMessage.success(props.task ? '活动任务已更新' : '活动任务已添加');
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动任务保存失败'));
    if (error instanceof ApiError && error.code === 'growth_campaign_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function validateForm(): string {
  if (!form.taskKey.trim()) return '请填写任务标识';
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(form.taskKey.trim())) return '任务标识格式不正确';
  if (!form.title.trim()) return '请填写任务名称';
  if (!form.eventName) return '请选择触发事件';
  if (contentEvent.value && form.contentKey && !form.contentType) return '选择指定内容前请先选择内容类型';
  if (form.changeNote.trim().length < 4) return '请填写具体的任务变更原因';
  return '';
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    width="min(680px, 94vw)"
    append-to-body
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="dialog-heading">
        <span>CAMPAIGN TASK</span>
        <h2>{{ editing ? '编辑活动任务' : '添加活动任务' }}</h2>
        <p>进度产生后锁定完成条件，奖励领取后锁定奖励金额。</p>
      </div>
    </template>

    <div class="task-form">
      <ElAlert
        v-if="identityLocked || rewardLocked"
        :title="identityLocked ? '该任务已有用户进度' : '该任务已有奖励领取记录'"
        :description="identityLocked ? '事件、目标数量与内容范围已锁定；仍可修改名称、说明、排序和状态。' : '奖励金额已锁定，避免历史账目与当前配置不一致。'"
        type="warning"
        :closable="false"
        show-icon
      />

      <ElAlert
        v-if="loginEvent"
        title="登录赠币任务"
        description="活动期间用户打开 App 后自动发放，每人一次；活动标题和任务说明将用于获奖弹窗。"
        type="info"
        :closable="false"
        show-icon
      />

      <div class="form-grid">
        <ElFormItem label="任务标识" required>
          <ElInput v-model="form.taskKey" :disabled="identityLocked" maxlength="120" placeholder="start-reading" />
        </ElFormItem>
        <ElFormItem label="任务状态" required>
          <ElSelect v-model="form.status">
            <ElOption label="有效" value="active" />
            <ElOption label="停用" value="disabled" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem class="wide" label="任务名称" required>
          <ElInput v-model="form.title" maxlength="100" show-word-limit placeholder="用户在任务列表中看到的名称" />
        </ElFormItem>
        <ElFormItem class="wide" label="任务说明">
          <ElInput v-model="form.description" type="textarea" :rows="2" maxlength="500" show-word-limit placeholder="简要说明完成方式" />
        </ElFormItem>
        <ElFormItem label="触发事件" required>
          <ElSelect v-model="form.eventName" :disabled="identityLocked" filterable>
            <ElOption v-for="event in detail.options.taskEvents" :key="event" :label="growthEventLabel(event)" :value="event" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem label="目标次数" required>
          <ElInputNumber v-model="form.targetCount" :min="1" :max="1000000" :disabled="identityLocked || loginEvent" controls-position="right" />
        </ElFormItem>
      </div>

      <section v-if="contentEvent" class="task-section">
        <header><ElIcon><Search /></ElIcon><div><strong>内容范围</strong><small>留空表示所有内容；也可以逐级限定类型与具体作品。</small></div></header>
        <div class="form-grid">
          <ElFormItem label="内容类型">
            <ElSelect v-model="form.contentType" :disabled="identityLocked" clearable placeholder="全部类型">
              <ElOption v-for="type in detail.options.contentTypes" :key="type" :label="growthContentTypeLabel(type)" :value="type" />
            </ElSelect>
          </ElFormItem>
          <ElFormItem label="指定内容">
            <ElSelect
              v-model="form.contentKey"
              :disabled="identityLocked"
              clearable
              filterable
              remote
              :remote-method="searchCatalog"
              :loading="searching"
              placeholder="可选，输入标题搜索"
            >
              <ElOption v-for="item in catalog" :key="item.stableKey" :label="item.title" :value="item.stableKey">
                <span>{{ item.title }}</span><small>{{ growthContentTypeLabel(item.contentType) }} · {{ item.author || item.stableKey }}</small>
              </ElOption>
            </ElSelect>
          </ElFormItem>
        </div>
      </section>

      <section class="task-section reward-section">
        <header><ElIcon><Coin /></ElIcon><div><strong>单用户奖励</strong><small>活动启用前会按覆盖人数计算最大预算。</small></div></header>
        <div class="form-grid reward-grid">
          <ElFormItem label="成长值">
            <ElInputNumber v-model="form.rewardPoints" :min="0" :max="100000" :disabled="rewardLocked" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="樱花币">
            <ElInputNumber v-model="form.rewardCoins" :min="0" :max="100000" :disabled="rewardLocked" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="显示顺序">
            <ElInputNumber v-model="form.sortOrder" :min="-100000" :max="100000" :step="10" controls-position="right" />
          </ElFormItem>
        </div>
      </section>

      <section class="note-section">
        <header><ElIcon><Tickets /></ElIcon><div><strong>变更说明</strong><small>记录任务配置的业务依据。</small></div></header>
        <ElInput v-model="form.changeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明为什么添加或修改该任务" />
      </section>
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="save">{{ editing ? '保存任务' : '添加任务' }}</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.dialog-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.dialog-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.task-form { display: grid; gap: 15px; }
.form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
.form-grid .wide { grid-column: 1 / -1; }
.form-grid :deep(.el-form-item__label) { justify-content: flex-start; }
.form-grid :deep(.el-select), .form-grid :deep(.el-input-number) { width: 100%; }
.task-section, .note-section { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.task-section > header, .note-section > header { display: flex; align-items: flex-start; gap: 9px; margin-bottom: 12px; }
.task-section > header > .el-icon, .note-section > header > .el-icon { margin-top: 2px; color: var(--sakura-600); }
.task-section header div, .note-section header div { display: grid; gap: 3px; }
.task-section header strong, .note-section header strong { color: var(--ink-900); font-size: 12px; }
.task-section header small, .note-section header small { color: var(--ink-500); font-size: 10px; line-height: 1.45; }
.reward-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.note-section { display: grid; grid-template-columns: minmax(150px, .55fr) minmax(240px, 1.45fr); gap: 12px; }
.note-section > header { margin-bottom: 0; }
@media (max-width: 580px) {
  .form-grid, .reward-grid, .note-section { grid-template-columns: 1fr; }
  .form-grid > * { grid-column: 1 !important; }
}
</style>
