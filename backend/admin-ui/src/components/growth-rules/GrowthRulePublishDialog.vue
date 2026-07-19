<script setup lang="ts">
import { WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { publishGrowthRulesDraft } from '@/services/growth-rules';
import type {
  GrowthRuleImpact,
  GrowthRulesWorkbenchResponse,
  GrowthRuleSetRecord,
} from '@/types/growth-rules';

const props = defineProps<{
  modelValue: boolean;
  draft: GrowthRuleSetRecord | null;
  impact: GrowthRuleImpact | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  published: [value: GrowthRulesWorkbenchResponse];
}>();

const note = ref('');
const acknowledgeImpact = ref(false);
const saving = ref(false);
const risky = computed(
  () =>
    Number(props.impact?.levelDownUsers || 0) > 0 ||
    Number(props.impact?.dailyCapReducedUsers || 0) > 0,
);
const canPublish = computed(
  () => Boolean(note.value.trim()) && (!risky.value || acknowledgeImpact.value),
);

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    note.value = '';
    acknowledgeImpact.value = false;
  },
);

async function publish(): Promise<void> {
  if (!props.draft || !canPublish.value) return;
  saving.value = true;
  try {
    const result = await publishGrowthRulesDraft({
      expectedEditVersion: props.draft.editVersion,
      note: note.value.trim(),
      acknowledgeImpact: acknowledgeImpact.value,
    });
    emit('published', result);
    emit('update:modelValue', false);
    ElMessage.success(`成长规则版本 ${result.active.revision} 已发布`);
  } catch (error) {
    ElMessage.error(errorMessage(error, '发布成长规则失败'));
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
    width="min(620px, 94vw)"
    destroy-on-close
    title="发布成长规则"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div v-if="draft && impact" class="publish-body">
      <div class="version-line">
        <span>当前版本 {{ draft.baseRevision }}</span>
        <strong>发布为版本 {{ draft.revision }}</strong>
      </div>
      <div class="impact-grid">
        <div><span>等级变化</span><strong>{{ impact.affectedLevelUsers }}</strong><small>位用户</small></div>
        <div class="positive"><span>升级</span><strong>{{ impact.levelUpUsers }}</strong><small>位用户</small></div>
        <div :class="{ danger: impact.levelDownUsers }"><span>降级</span><strong>{{ impact.levelDownUsers }}</strong><small>位用户</small></div>
        <div :class="{ danger: impact.dailyCapReducedUsers }"><span>上限降低</span><strong>{{ impact.dailyCapReducedUsers }}</strong><small>位用户</small></div>
      </div>
      <div v-if="risky" class="risk-notice">
        <ElIcon><WarningFilled /></ElIcon>
        <div><strong>存在用户权益降低</strong><p>发布只改变等级解释与后续每日奖励上限，不会扣除已有成长值或樱花币。</p></div>
      </div>
      <ElFormItem label="发布依据" required>
        <ElInput
          v-model="note"
          type="textarea"
          :rows="3"
          maxlength="300"
          show-word-limit
          resize="none"
          placeholder="填写评审结论、数据依据或生效范围"
        />
      </ElFormItem>
      <ElCheckbox v-if="risky" v-model="acknowledgeImpact">
        已核对降级与每日上限降低用户，确认立即生效
      </ElCheckbox>
    </div>
    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" :disabled="!canPublish" @click="publish">确认发布</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.publish-body { display: grid; gap: 16px; }
.version-line { display: flex; justify-content: space-between; gap: 16px; padding-bottom: 11px; border-bottom: 1px solid var(--line); color: var(--ink-500); font-size: 12px; }
.version-line strong { color: var(--ink-900); }
.impact-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; }
.impact-grid > div { min-width: 0; display: grid; gap: 3px; padding: 12px; border-right: 1px solid var(--line); }
.impact-grid > div:last-child { border-right: 0; }
.impact-grid span, .impact-grid small { color: var(--ink-500); font-size: 10px; }
.impact-grid strong { color: var(--ink-900); font-size: 20px; }
.impact-grid .positive strong { color: #2e7b5d; }
.impact-grid .danger strong { color: #b14e58; }
.risk-notice { display: grid; grid-template-columns: auto 1fr; gap: 10px; padding: 12px; border: 1px solid #efd3a2; border-radius: 8px; color: #8c5a16; background: #fff8ec; }
.risk-notice strong { font-size: 13px; }
.risk-notice p { margin: 3px 0 0; font-size: 11px; line-height: 1.5; }
@media (max-width: 560px) {
  .impact-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .impact-grid > div:nth-child(2) { border-right: 0; }
  .impact-grid > div:nth-child(-n+2) { border-bottom: 1px solid var(--line); }
}
</style>
