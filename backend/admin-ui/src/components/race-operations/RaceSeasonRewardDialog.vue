<script setup lang="ts">
import { Coin, Lock, Medal, Tickets } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { createRaceSeasonReward, updateRaceSeasonReward } from '@/services/race-operations';
import type {
  RaceItemStatus,
  RaceSeasonDetailResponse,
  RaceSeasonReward,
} from '@/types/race-operations';
import { raceTierLabel } from '@/utils/race-operations';

const props = defineProps<{
  modelValue: boolean;
  detail: RaceSeasonDetailResponse;
  reward: RaceSeasonReward | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: RaceSeasonDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const form = reactive({
  rewardKey: '',
  title: '',
  tier: '',
  minRank: 1,
  maxRank: 1,
  rewardPoints: 0,
  rewardCoins: 0,
  status: 'active' as RaceItemStatus,
  changeNote: '',
});

const editing = computed(() => Boolean(props.reward));
const termsLocked = computed(() => Boolean(props.reward && (
  props.reward.termsLocked || props.detail.item.participants > 0
)));

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    Object.assign(form, {
      rewardKey: props.reward?.rewardKey || '',
      title: props.reward?.title || '',
      tier: props.reward?.tier || '',
      minRank: props.reward?.minRank ?? 1,
      maxRank: props.reward?.maxRank ?? 1,
      rewardPoints: props.reward?.rewardPoints || 0,
      rewardCoins: props.reward?.rewardCoins || 0,
      status: props.reward?.status || 'active',
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
      rewardKey: form.rewardKey.trim(),
      title: form.title.trim(),
      tier: form.tier,
      minRank: form.minRank,
      maxRank: form.maxRank,
      rewardPoints: form.rewardPoints,
      rewardCoins: form.rewardCoins,
      status: form.status,
      changeNote: form.changeNote.trim(),
    };
    const result = props.reward
      ? await updateRaceSeasonReward(props.detail.item.id, props.reward.id, payload)
      : await createRaceSeasonReward(props.detail.item.id, payload);
    ElMessage.success(props.reward ? '排名奖励已更新' : '排名奖励已添加');
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '排名奖励保存失败'));
    if (error instanceof ApiError && error.code === 'race_season_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function validateForm(): string {
  if (!form.rewardKey.trim()) return '请填写奖励标识';
  if (!/^[a-z0-9][a-z0-9._:-]*$/.test(form.rewardKey.trim())) return '奖励标识格式不正确';
  if (!form.title.trim()) return '请填写奖励名称';
  if (form.maxRank > 0 && form.maxRank < Math.max(1, form.minRank)) return '结束名次不能小于开始名次';
  if (!form.rewardPoints && !form.rewardCoins) return '成长值或樱花币至少填写一项';
  if (form.changeNote.trim().length < 4) return '请填写具体的奖励变更原因';
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
        <span>RANK REWARD</span>
        <h2>{{ editing ? '编辑排名奖励' : '添加排名奖励' }}</h2>
        <p>段位与名次条件同时填写时，用户需要同时满足两项条件。</p>
      </div>
    </template>

    <div class="reward-form">
      <ElAlert
        v-if="termsLocked"
        title="奖励条款已经锁定"
        description="赛季已有参与者或发放记录，只能修正展示名称，不能改变范围、金额或状态。"
        type="warning"
        :closable="false"
        show-icon
      />

      <div class="form-grid">
        <ElFormItem label="奖励标识" required>
          <ElInput v-model="form.rewardKey" :disabled="termsLocked" maxlength="120" placeholder="top-three" />
        </ElFormItem>
        <ElFormItem label="奖励状态" required>
          <ElSelect v-model="form.status" :disabled="termsLocked">
            <ElOption label="有效" value="active" />
            <ElOption label="停用" value="disabled" />
          </ElSelect>
        </ElFormItem>
        <ElFormItem class="wide" label="奖励名称" required>
          <ElInput v-model="form.title" maxlength="100" show-word-limit placeholder="用户看到的奖励名称" />
        </ElFormItem>
      </div>

      <section class="scope-section">
        <header><ElIcon><Medal /></ElIcon><div><strong>获奖范围</strong><small>段位留空表示不限；结束名次填 0 表示该开始名次之后的所有用户。</small></div></header>
        <div class="scope-grid">
          <ElFormItem label="指定段位">
            <ElSelect v-model="form.tier" :disabled="termsLocked" clearable placeholder="不限段位">
              <ElOption v-for="tier in detail.item.config.tiers" :key="tier.key" :label="`${raceTierLabel(tier.key)} · ${tier.points} 分`" :value="tier.key" />
            </ElSelect>
          </ElFormItem>
          <ElFormItem label="开始名次">
            <ElInputNumber v-model="form.minRank" :disabled="termsLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="结束名次">
            <ElInputNumber v-model="form.maxRank" :disabled="termsLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
        </div>
      </section>

      <section class="amount-section">
        <header><ElIcon><Coin /></ElIcon><div><strong>奖励金额</strong><small>赛季结算时按最终榜单一次性发放。</small></div></header>
        <div class="amount-grid">
          <ElFormItem label="成长值">
            <ElInputNumber v-model="form.rewardPoints" :disabled="termsLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
          <ElFormItem label="樱花币">
            <ElInputNumber v-model="form.rewardCoins" :disabled="termsLocked" :min="0" :max="1000000" controls-position="right" />
          </ElFormItem>
        </div>
      </section>

      <section v-if="termsLocked" class="lock-note"><ElIcon><Lock /></ElIcon><span>锁定用于保证已公布奖励与最终发放账目一致。</span></section>

      <section class="note-section">
        <header><ElIcon><Tickets /></ElIcon><div><strong>变更说明</strong><small>记录奖励范围和金额的审核依据。</small></div></header>
        <ElInput v-model="form.changeNote" type="textarea" :rows="3" maxlength="500" show-word-limit placeholder="说明为什么添加或修改该奖励" />
      </section>
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="save">{{ editing ? '保存奖励' : '添加奖励' }}</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.dialog-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.dialog-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 11px; }
.reward-form { display: grid; gap: 14px; }
.form-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0 14px; }
.form-grid .wide { grid-column: 1 / -1; }
.form-grid :deep(.el-form-item__label), .scope-grid :deep(.el-form-item__label), .amount-grid :deep(.el-form-item__label) { justify-content: flex-start; }
.form-grid :deep(.el-select), .scope-grid :deep(.el-select), .scope-grid :deep(.el-input-number), .amount-grid :deep(.el-input-number) { width: 100%; }
.scope-section, .amount-section, .note-section { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface-muted); }
.scope-section > header, .amount-section > header, .note-section > header { display: flex; align-items: flex-start; gap: 8px; margin-bottom: 11px; }
.scope-section header > .el-icon, .amount-section header > .el-icon, .note-section header > .el-icon { margin-top: 2px; color: var(--sakura-600); }
.scope-section header div, .amount-section header div, .note-section header div { display: grid; gap: 3px; }
.scope-section strong, .amount-section strong, .note-section strong { color: var(--ink-900); font-size: 12px; }
.scope-section small, .amount-section small, .note-section small { color: var(--ink-500); font-size: 9px; line-height: 1.45; }
.scope-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.amount-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.note-section { display: grid; grid-template-columns: minmax(140px, .55fr) minmax(240px, 1.45fr); gap: 12px; }
.note-section > header { margin-bottom: 0; }
.lock-note { display: flex; align-items: center; gap: 7px; color: #7e642d; font-size: 10px; }
@media (max-width: 580px) {
  .form-grid, .scope-grid, .amount-grid, .note-section { grid-template-columns: 1fr; }
  .form-grid > * { grid-column: 1 !important; }
}
</style>
