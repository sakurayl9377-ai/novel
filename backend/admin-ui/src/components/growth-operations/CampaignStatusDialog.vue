<script setup lang="ts">
import { Coin, Promotion, SwitchButton, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { ApiError } from '@/services/api';
import { transitionGrowthCampaign } from '@/services/growth-operations';
import type {
  CampaignDetailResponse,
  CampaignStatus,
} from '@/types/growth-operations';
import {
  campaignAudienceLabel,
  campaignTransitionLabel,
} from '@/utils/growth-operations';

const props = defineProps<{
  modelValue: boolean;
  detail: CampaignDetailResponse | null;
  target: CampaignStatus | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  saved: [detail: CampaignDetailResponse];
  reload: [];
}>();

const saving = ref(false);
const note = ref('');
const acknowledged = ref(false);

const activating = computed(() => props.target === 'active');
const ending = computed(() => props.target === 'ended');

watch(
  () => props.modelValue,
  (open) => {
    if (open) {
      note.value = '';
      acknowledged.value = false;
    }
  },
);

async function save(): Promise<void> {
  if (!props.detail || !props.target) return;
  if (note.value.trim().length < 4) {
    ElMessage.warning('请填写具体的状态变更原因');
    return;
  }
  if ((activating.value || ending.value) && !acknowledged.value) {
    ElMessage.warning(activating.value ? '请先确认奖励预算与活动范围' : '请确认活动结束后不能恢复');
    return;
  }
  saving.value = true;
  try {
    const result = await transitionGrowthCampaign(props.detail.item.id, {
      status: props.target,
      expectedRevision: props.detail.item.revision,
      note: note.value.trim(),
      ...(activating.value ? { acknowledgeBudget: true } : {}),
    });
    ElMessage.success(`${campaignTransitionLabel(props.target)}成功`);
    emit('saved', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '活动状态变更失败'));
    if (error instanceof ApiError && error.code === 'growth_campaign_revision_conflict') {
      emit('reload');
      emit('update:modelValue', false);
    }
  } finally {
    saving.value = false;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    width="min(600px, 94vw)"
    destroy-on-close
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="dialog-heading">
        <span>CAMPAIGN LIFECYCLE</span>
        <h2>{{ target ? campaignTransitionLabel(target) : '活动状态' }}</h2>
        <p>{{ detail?.item.title }} · 当前版本 {{ detail?.item.revision }}</p>
      </div>
    </template>

    <template v-if="detail && target">
      <section v-if="activating" class="budget-review">
        <header><ElIcon><Promotion /></ElIcon><div><strong>上线前预算复核</strong><small>{{ campaignAudienceLabel(detail.budget.audiencePreset) }} · {{ detail.budget.activeTasks }} 个有效任务</small></div></header>
        <dl>
          <div><dt>预计覆盖</dt><dd>{{ detail.budget.eligibleUsers.toLocaleString() }}<small>用户</small></dd></div>
          <div><dt>单用户成长值</dt><dd>{{ detail.budget.perUserPoints.toLocaleString() }}</dd></div>
          <div><dt>单用户樱花币</dt><dd>{{ detail.budget.perUserCoins.toLocaleString() }}</dd></div>
          <div><dt>成长值上限</dt><dd>{{ detail.budget.potentialPoints.toLocaleString() }}</dd></div>
          <div><dt>樱花币上限</dt><dd>{{ detail.budget.potentialCoins.toLocaleString() }}</dd></div>
        </dl>
        <ElAlert
          v-if="!detail.item.bannerUrl || !detail.item.startsAt || !detail.item.endsAt || !detail.item.activeTaskCount"
          title="活动尚未满足启用条件"
          description="请检查横幅、完整时间范围和至少一个有效任务。"
          type="warning"
          :closable="false"
          show-icon
        />
      </section>

      <section v-else class="status-impact" :class="{ danger: ending }">
        <ElIcon><WarningFilled v-if="ending" /><SwitchButton v-else /></ElIcon>
        <div>
          <strong>{{ ending ? '结束是不可逆操作' : '暂停后用户将看不到活动，也不会再累计任务进度' }}</strong>
          <p>{{ ending ? '活动、任务、用户进度和奖励领取记录都会保留用于审计，但该活动不能重新启用。' : '暂停期间可以安全修改配置或恢复历史版本，复核后再重新启用。' }}</p>
        </div>
      </section>

      <ElFormItem label="操作原因" required class="note-field">
        <ElInput v-model="note" type="textarea" :rows="3" maxlength="500" show-word-limit :placeholder="activating ? '说明预算、时间和任务已由谁复核' : '说明暂停或结束活动的原因'" />
      </ElFormItem>

      <ElCheckbox v-if="activating || ending" v-model="acknowledged" class="acknowledgement">
        <span v-if="activating"><ElIcon><Coin /></ElIcon>我已核对目标人群、时间范围和最大成长值 / 樱花币预算</span>
        <span v-else>我确认活动结束后不能恢复或重新启用</span>
      </ElCheckbox>
    </template>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton :type="ending ? 'danger' : 'primary'" :loading="saving" @click="save">
        {{ target ? campaignTransitionLabel(target) : '确认' }}
      </ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.dialog-heading span { color: var(--sakura-600); font-size: 10px; font-weight: 800; letter-spacing: .1em; }
.dialog-heading h2 { margin: 5px 0 3px; color: var(--ink-900); font-size: 20px; letter-spacing: 0; }
.dialog-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }
.budget-review { display: grid; gap: 13px; padding: 15px; border: 1px solid #cfe1ee; border-radius: 8px; background: #f5fafd; }
.budget-review header { display: flex; align-items: flex-start; gap: 9px; }
.budget-review header > .el-icon { margin-top: 2px; color: #39769b; }
.budget-review header div { display: grid; gap: 3px; }
.budget-review header strong { color: #285978; font-size: 13px; }
.budget-review header small { color: #5e7e91; font-size: 10px; }
.budget-review dl { margin: 0; display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); border-top: 1px solid #d8e7f0; }
.budget-review dl div { min-width: 0; display: grid; gap: 4px; padding: 11px 8px 2px; border-right: 1px solid #d8e7f0; }
.budget-review dl div:last-child { border-right: 0; }
.budget-review dt { color: #5e7e91; font-size: 10px; }
.budget-review dd { margin: 0; color: #285978; font-size: 17px; font-weight: 800; letter-spacing: 0; overflow-wrap: anywhere; }
.budget-review dd small { margin-left: 3px; font-size: 9px; font-weight: 500; }
.status-impact { display: flex; align-items: flex-start; gap: 11px; padding: 14px; border: 1px solid #eadcad; border-radius: 8px; color: #7b622b; background: #fffaf0; }
.status-impact.danger { border-color: #efcbd3; color: #984257; background: #fff5f7; }
.status-impact > .el-icon { margin-top: 2px; font-size: 18px; }
.status-impact strong { font-size: 13px; }
.status-impact p { margin: 5px 0 0; font-size: 11px; line-height: 1.55; }
.note-field { display: grid; margin: 17px 0 12px; }
.note-field :deep(.el-form-item__label) { justify-content: flex-start; }
.acknowledgement { height: auto; align-items: flex-start; white-space: normal; }
.acknowledgement span { display: inline-flex; align-items: center; gap: 5px; line-height: 1.5; white-space: normal; }
@media (max-width: 560px) {
  .budget-review dl { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .budget-review dl div { border-bottom: 1px solid #d8e7f0; }
}
</style>
