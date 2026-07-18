<script setup lang="ts">
import { Lock, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, watch } from 'vue';

import type { AdminUser, UserBanPayload } from '@/types/user';

const props = defineProps<{
  modelValue: boolean;
  user: AdminUser | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [payload: UserBanPayload];
}>();

const form = reactive<UserBanPayload>({
  mode: 'temporary',
  durationHours: 24,
  reasonCode: 'community_violation',
  note: '',
  blockKnownIps: false,
});

const impactText = computed(() => form.mode === 'permanent'
  ? '账号将保持封禁，直到管理员手动解封。'
  : `账号将在 ${durationLabel(Number(form.durationHours || 24))} 后自动恢复，但旧登录会话不会恢复。`);

watch(
  () => props.modelValue,
  (open) => {
    if (!open) return;
    Object.assign(form, {
      mode: 'temporary',
      durationHours: 24,
      reasonCode: 'community_violation',
      note: '',
      blockKnownIps: false,
    });
  },
);

function submit(): void {
  if (!form.reasonCode) {
    ElMessage.warning('请选择封禁原因');
    return;
  }
  emit('submit', {
    mode: form.mode,
    ...(form.mode === 'temporary' ? { durationHours: form.durationHours } : {}),
    reasonCode: form.reasonCode,
    note: form.note.trim(),
    blockKnownIps: form.blockKnownIps,
  });
}

function durationLabel(hours: number): string {
  return ({ 1: '1 小时', 24: '1 天', 72: '3 天', 168: '7 天', 720: '30 天' } as Record<number, string>)[hours]
    || `${hours} 小时`;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="封禁用户"
    width="min(560px, 94vw)"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div class="ban-target">
      <ElAvatar :src="user?.avatarUrl" :size="42">{{ user?.nickname?.slice(0, 1) }}</ElAvatar>
      <div><strong>{{ user?.nickname }}</strong><span>{{ user?.email }} · UID {{ user?.id }}</span></div>
      <ElIcon><Lock /></ElIcon>
    </div>

    <ElForm label-position="top">
      <ElFormItem label="封禁方式" required>
        <ElRadioGroup v-model="form.mode">
          <ElRadioButton value="temporary">限时封禁</ElRadioButton>
          <ElRadioButton value="permanent">永久封禁</ElRadioButton>
        </ElRadioGroup>
      </ElFormItem>
      <ElFormItem v-if="form.mode === 'temporary'" label="封禁时长" required>
        <ElSelect v-model="form.durationHours" class="full-width">
          <ElOption label="1 小时" :value="1" /><ElOption label="1 天（推荐）" :value="24" />
          <ElOption label="3 天" :value="72" /><ElOption label="7 天" :value="168" />
          <ElOption label="30 天" :value="720" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="封禁原因" required>
        <ElSelect v-model="form.reasonCode" class="full-width">
          <ElOption label="社区内容违规" value="community_violation" />
          <ElOption label="诈骗或交易风险" value="fraud" />
          <ElOption label="批量广告或骚扰" value="spam" />
          <ElOption label="账号安全风险" value="security_risk" />
          <ElOption label="账号滥用" value="account_abuse" />
          <ElOption label="其他原因" value="other" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="补充说明">
        <ElInput v-model="form.note" maxlength="120" show-word-limit placeholder="记录证据、工单或复核结论" />
      </ElFormItem>
      <div class="switch-row">
        <div><strong>同时封禁已知注册 IP</strong><span>会影响同网络下的新账号注册；仅在确认恶意批量注册时开启。</span></div>
        <ElSwitch v-model="form.blockKnownIps" />
      </div>
    </ElForm>

    <div class="impact-note">
      <ElIcon><WarningFilled /></ElIcon>
      <span>{{ impactText }} 当前所有登录会话会立即撤销，聊天室在线连接会断开。</span>
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="danger" :loading="saving" @click="submit">确认封禁</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.ban-target { display: flex; align-items: center; gap: 11px; padding: 13px; margin-bottom: 18px; border: 1px solid #f0dde3; border-radius: 14px; background: #fff9fb; }.ban-target > div { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }.ban-target strong { color: #48383f; }.ban-target span { overflow: hidden; color: #917d85; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.ban-target > :deep(.el-icon) { color: #d65778; font-size: 20px; }
.full-width { width: 100%; }.switch-row { display: flex; align-items: center; justify-content: space-between; gap: 20px; padding: 13px 0; border-top: 1px dashed #eadde2; }.switch-row > div { display: flex; flex-direction: column; gap: 4px; }.switch-row strong { color: #4d3e44; font-size: 13px; }.switch-row span { color: #97838b; font-size: 11px; line-height: 1.5; }
.impact-note { display: flex; gap: 8px; padding: 11px 13px; margin-top: 16px; border-radius: 12px; color: #a25765; background: #fff0f3; font-size: 11px; line-height: 1.55; }.impact-note :deep(.el-icon) { flex: 0 0 auto; margin-top: 2px; }
</style>
