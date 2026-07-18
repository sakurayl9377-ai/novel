<script setup lang="ts">
import { Refresh, WarningFilled } from '@element-plus/icons-vue';
import { ref, watch } from 'vue';

import type { AdminUser } from '@/types/user';

const props = defineProps<{
  modelValue: boolean;
  user: AdminUser | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [removeKnownIps: boolean];
}>();

const removeKnownIps = ref(false);

watch(
  () => props.modelValue,
  (open) => {
    if (open) removeKnownIps.value = false;
  },
);
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="解除用户封禁"
    width="min(540px, 94vw)"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div class="unban-target">
      <span class="target-icon"><ElIcon><Refresh /></ElIcon></span>
      <div>
        <strong>{{ user?.nickname }}</strong>
        <span>{{ user?.email }} · UID {{ user?.id }}</span>
      </div>
    </div>

    <div class="impact-note">
      <ElIcon><WarningFilled /></ElIcon>
      <div>
        <strong>账号会立即恢复正常状态</strong>
        <span>此前撤销的登录会话不会恢复，用户仍需重新登录。</span>
      </div>
    </div>

    <div class="switch-row">
      <div>
        <strong>同时移除该用户关联的注册 IP 黑名单</strong>
        <span>默认保留黑名单，避免其他恶意账号继续注册；确认误封或风险已解除时再开启。</span>
      </div>
      <ElSwitch v-model="removeKnownIps" />
    </div>

    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="success" :loading="saving" @click="emit('submit', removeKnownIps)">确认解封</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.unban-target { display: flex; align-items: center; gap: 11px; padding: 13px; margin-bottom: 14px; border: 1px solid #dcece2; border-radius: 14px; background: #f6fbf8; }.target-icon { display: grid; flex: 0 0 40px; width: 40px; height: 40px; place-items: center; border-radius: 12px; color: #33855a; background: #dff2e7; }.unban-target > div { display: flex; min-width: 0; flex-direction: column; gap: 3px; }.unban-target strong { color: #3f493f; }.unban-target span { overflow: hidden; color: #7d8d82; font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }
.impact-note { display: flex; gap: 9px; padding: 12px 13px; border-radius: 12px; color: #7b6540; background: #fff7e8; }.impact-note > div { display: flex; flex-direction: column; gap: 3px; }.impact-note strong { font-size: 12px; }.impact-note span { font-size: 11px; line-height: 1.5; }.impact-note :deep(.el-icon) { flex: 0 0 auto; margin-top: 2px; }
.switch-row { display: flex; align-items: center; justify-content: space-between; gap: 22px; padding: 16px 2px 4px; }.switch-row > div { display: flex; flex-direction: column; gap: 4px; }.switch-row strong { color: #4b3d43; font-size: 13px; }.switch-row span { max-width: 390px; color: #948087; font-size: 11px; line-height: 1.55; }
</style>
