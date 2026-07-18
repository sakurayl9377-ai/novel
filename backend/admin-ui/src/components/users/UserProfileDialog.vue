<script setup lang="ts">
import { EditPen } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { reactive, watch } from 'vue';

import type { AdminUser, UserProfilePayload } from '@/types/user';

const props = defineProps<{
  modelValue: boolean;
  user: AdminUser | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [payload: UserProfilePayload];
}>();

const form = reactive<UserProfilePayload>({ nickname: '', gender: 'private', signature: '', bio: '' });

watch(
  () => [props.modelValue, props.user] as const,
  ([open, user]) => {
    if (!open || !user) return;
    Object.assign(form, {
      nickname: user.nickname || '',
      gender: user.gender || 'private',
      signature: user.signature || '',
      bio: user.bio || '',
    });
  },
  { immediate: true },
);

function submit(): void {
  const nickname = form.nickname.trim();
  if (!nickname) {
    ElMessage.warning('昵称不能为空');
    return;
  }
  emit('submit', {
    nickname,
    gender: form.gender,
    signature: form.signature.trim(),
    bio: form.bio.trim(),
  });
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="编辑用户资料"
    width="min(560px, 94vw)"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <div class="profile-note">
      <ElIcon><EditPen /></ElIcon>
      <span>这里只修正展示资料，不修改邮箱、头像或登录凭据。</span>
    </div>
    <ElForm label-position="top">
      <ElFormItem label="昵称" required>
        <ElInput v-model="form.nickname" maxlength="32" show-word-limit />
      </ElFormItem>
      <ElFormItem label="性别展示">
        <ElSelect v-model="form.gender" class="full-width">
          <ElOption label="不公开" value="private" />
          <ElOption label="男" value="male" />
          <ElOption label="女" value="female" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="个性签名">
        <ElInput v-model="form.signature" maxlength="80" show-word-limit placeholder="可清空" />
      </ElFormItem>
      <ElFormItem label="个人简介">
        <ElInput v-model="form.bio" type="textarea" :rows="4" maxlength="140" show-word-limit placeholder="可清空" />
      </ElFormItem>
    </ElForm>
    <template #footer>
      <ElButton @click="emit('update:modelValue', false)">取消</ElButton>
      <ElButton type="primary" :loading="saving" @click="submit">保存资料</ElButton>
    </template>
  </ElDialog>
</template>

<style scoped>
.profile-note { display: flex; align-items: center; gap: 8px; padding: 11px 13px; margin-bottom: 17px; border-radius: 12px; color: #815f6c; background: #fff5f8; font-size: 12px; }
.profile-note :deep(.el-icon) { color: #ce5d83; }
.full-width { width: 100%; }
</style>
