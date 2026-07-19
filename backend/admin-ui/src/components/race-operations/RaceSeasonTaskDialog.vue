<script setup lang="ts">
import { Coin, Lock, Tickets } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { createRaceSeasonTask, updateRaceSeasonTask } from '@/services/race-operations';
import type {
  RaceItemStatus,
  RaceSeasonDetailResponse,
  RaceSeasonMetric,
  RaceSeasonTask,
} from '@/types/race-operations';
import { raceMetricLabel } from '@/utils/race-operations';

const props = defineProps<{
  modelValue: boolean;
  detail: RaceSeasonDetailResponse;
  task: RaceSeasonTask | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: RaceSeasonDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const form = reactive({
  taskKey: '',
  title: '',
  metric: 'rounds' as RaceSeasonMetric,
  targetCount: 1,
  rewardPoints: 0,
  rewardCoins: 0,
  status: 'active' as RaceItemStatus,
  sortOrder: 0,
  changeNote: '',
});

const editing = computed(() => Boolean(props.task));
const identityLocked = computed(() => Boolean(props.task?.identityLocked));
const rewardLocked = computed(() => Boolean(props.task?.rewardLocked));
const statusLocked = computed(() => Boolean(props.task?.progressUsers));

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    Object.assign(form, {
      taskKey: props.task?.taskKey || '',
      title: props.task?.title || '',
      metric: props.task?.metric || 'rounds',
      targetCount: props.task?.targetCount || 1,
      rewardPoints: props.task?.rewardPoints || 0,
      rewardCoins: props.task?.rewardCoins || 0,
      status: props.task?.status || 'active',
      sortOrder: props.task?.sortOrder ?? props.detail.tasks.length * 10,
      changeNote: '',
    });
  },
);

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
      metric: form.metric,
      targetCount: form.targetCount,
      rewardPoints: form.rewardPoints,
      rewardCoins: form.rewardCoins,
      status: form.status,
      sortOrder: form.sortOrder,
      changeNote: form.changeNote.trim(),
    };
    const result = props.task
      ? await updateRaceSeasonTask(props.detail.item.id, props.task.id, payload)
      : await createRaceSeasonTask(props.detail.item.id, payload);
    ElMessage.success(props.task ? '赛季任务已更新' : '赛季任务已添加');
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '赛季任务保存失败'));
    if (error instanceof ApiError && error.code === 'race_season_revision_conflict') {
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
  if (!form.metric) return '请选择任务指标';
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
    width="min(660px, 94vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="dialog-heading">
        <span>SEASON TASK</span>
        <h2>{{ editing ? '编辑赛季任务' : '添加赛季任务' }}</h2>
        <p>进度产生后锁定完成条件；奖励领取后锁定奖励金额。</p>
      </div>
    </template>

    <div class="task-form">
      <ElAlert
        v-if="identityLocked || rewardLocked"
        :title="identityLocked ? '该任务已有用户进度' : '该任务已有领取记录'"
        :description="identityLocked ? '任务标识、指标、目标数量和状态已锁定。' : '成长值与樱花币奖励已锁定。'"
        type="warning"
        :closable="false"
        show-icon
      />

      <div class="form-grid">
        <ElFormItem label="任务标识" required>
          <ElInput v-model="form.taskKey" :disabled="identityLocked" maxlength="120" placeholder="finish-three-rounds" />
        </ElFormItem>
        <ElFormItem label="任务状态" required>
          <ElSelect v-model="form.status" :disabled="statusLocked">
            <ElOption label="有效" value="active" />
            <ElOption label="停用" value="disabled" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem class="wide" label="任务名称" required>
          <ElInput v-model="form.title" maxlength="100" show-word-limit placeholder="用户在赛季任务中看到的名称" />
        </ElFormItem>
        <ElFormItem label="统计指标" required>
          <ElSelect v-model="form.metric" :disabled="identityLocked">
            <ElOption v-for="metric in detail.options.seasonMetrics" :key="metric" :label="raceMetricLabel(metric)" :value="metric" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem label="目标数量" required>
          <ElInputNumber v-model="form.targetCount" :disabled="identityLocked" :min="1" :max="10000000" controls-position="right" />
        </ElFormItem>
      </div>

      <section class="reward-section">
        <header><ElIcon><Coin /></ElIcon><div><strong>完成奖励</strong><small>按所有有效用户计算最大预算，用户完成后可领取一次。</small></div></header>
        <div class="reward-grid">
          <ElFormItem label="成长值">
            <ElInputNumber v-model="form.rewardPoints" :disabled="rewardLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="樱花币">
            <ElInputNumber v-model="form.rewardCoins" :disabled="rewardLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="显示顺序">
            <ElInputNumber v-model="form.sortOrder" :min="-100000" :max="100000" :step="10" controls-position="right" />
          </ElFormItem>
        </div>
      </section>

      <section class="lock-note" v-if="identityLocked || rewardLocked">
        <ElIcon><Lock /></ElIcon><span>锁定字段用于保证用户已看到的规则与历史账目保持一致。</span>
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
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 11px; }
.task-form { display: grid; gap: 14px; }
.form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
.form-grid .wide { grid-column: 1 / -1; }
.form-grid :deep(.el-form-item__label), .reward-grid :deep(.el-form-item__label) { justify-content: flex-start; }
.form-grid :deep(.el-select), .form-grid :deep(.el-input-number), .reward-grid :deep(.el-input-number) { width: 100%; }
.reward-section, .note-section { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.reward-section > header, .note-section > header { display: flex; align-items: flex-start; gap: 8px; margin-bottom: 11px; }
.reward-section header > .el-icon, .note-section header > .el-icon { margin-top: 2px; color: var(--sakura-600); }
.reward-section header div, .note-section header div { display: grid; gap: 3px; }
.reward-section strong, .note-section strong { color: var(--ink-900); font-size: 12px; }
.reward-section small, .note-section small { color: var(--ink-500); font-size: 9px; line-height: 1.45; }
.reward-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.note-section { display: grid; grid-template-columns: minmax(140px, .55fr) minmax(240px, 1.45fr); gap: 12px; }
.note-section > header { margin-bottom: 0; }
.lock-note { display: flex; align-items: center; gap: 7px; color: #7e642d; font-size: 10px; }
@media (max-width: 580px) {
  .form-grid, .reward-grid, .note-section { grid-template-columns: 1fr; }
  .form-grid > * { grid-column: 1 !important; }
}
</style>
