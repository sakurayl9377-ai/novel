<script setup lang="ts">
import { CircleCheck, Lock, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, reactive, watch } from 'vue';

import type { ChatKeywordPayload, ChatKeywordRule } from '@/types/chat';
import { chatKeywordMatches } from '@/utils/chat';

const props = defineProps<{
  modelValue: boolean;
  rule: ChatKeywordRule | null;
  saving?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  submit: [payload: ChatKeywordPayload];
}>();

const form = reactive<ChatKeywordPayload>({
  keyword: '',
  matchType: 'contains',
  status: 'active',
  note: '',
});
const sample = defineModel<string>('sample', { default: '' });

const editing = computed(() => Boolean(props.rule));
const localMatched = computed(() => chatKeywordMatches(form.keyword, form.matchType, sample.value));

watch(
  () => [props.modelValue, props.rule] as const,
  ([open, rule]) => {
    if (!open) return;
    Object.assign(form, {
      keyword: rule?.keyword || '',
      matchType: rule?.matchType || 'contains',
      status: rule?.status || 'active',
      note: rule?.note || '',
    });
    sample.value = '';
  },
  { immediate: true },
);

function close(): void {
  emit('update:modelValue', false);
}

function submit(): void {
  const keyword = form.keyword.trim();
  if (!keyword) {
    ElMessage.warning('请填写需要拦截的关键词');
    return;
  }
  emit('submit', {
    keyword,
    matchType: form.matchType,
    status: form.status,
    note: form.note.trim(),
    severity: 'block',
  });
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    :title="editing ? '编辑关键词规则' : '新增关键词规则'"
    size="min(520px, 94vw)"
    @close="close"
  >
    <div class="rule-notice">
      <ElIcon><Lock /></ElIcon>
      <div>
        <strong>命中后会阻止消息发送</strong>
        <p>系统会记录违规次数；同一用户当天多次命中后，按现有策略升级为临时或永久封禁。</p>
      </div>
    </div>

    <ElForm label-position="top">
      <ElFormItem label="关键词" required>
        <ElInput v-model="form.keyword" maxlength="80" show-word-limit placeholder="输入需要拦截的词语" />
      </ElFormItem>
      <ElFormItem label="匹配方式" required>
        <ElSelect v-model="form.matchType" class="full-width">
          <ElOption label="包含即命中（推荐）" value="contains">
            <span>包含即命中</span><small> 适合常规敏感词</small>
          </ElOption>
          <ElOption label="整句精确匹配" value="exact">
            <span>整句精确匹配</span><small> 适合避免误伤的短词</small>
          </ElOption>
        </ElSelect>
      </ElFormItem>
      <ElFormItem v-if="editing" label="规则状态">
        <ElSelect v-model="form.status" class="full-width">
          <ElOption label="启用" value="active" />
          <ElOption label="停用" value="inactive" />
        </ElSelect>
      </ElFormItem>
      <ElFormItem label="运营备注">
        <ElInput v-model="form.note" maxlength="120" show-word-limit placeholder="例如：广告导流词，2026-07 加入" />
      </ElFormItem>

      <div class="sample-box">
        <div class="sample-heading">
          <strong>保存前试一试</strong>
          <span>本地预览使用与服务端一致的大小写、空格和标点归一化规则</span>
        </div>
        <ElInput v-model="sample" type="textarea" :rows="3" maxlength="200" placeholder="输入一条示例聊天消息" />
        <div v-if="sample" class="sample-result" :class="{ matched: localMatched }">
          <ElIcon><WarningFilled v-if="localMatched" /><CircleCheck v-else /></ElIcon>
          <span>{{ localMatched ? '这条示例消息会被拦截' : '这条示例消息不会命中当前规则' }}</span>
        </div>
      </div>
    </ElForm>

    <template #footer>
      <div class="drawer-actions">
        <ElButton @click="close">取消</ElButton>
        <ElButton type="primary" :loading="saving" @click="submit">
          {{ editing ? '保存规则' : '启用规则' }}
        </ElButton>
      </div>
    </template>
  </ElDrawer>
</template>

<style scoped>
.rule-notice { display: flex; gap: 12px; padding: 15px; margin-bottom: 22px; border: 1px solid #f4d5df; border-radius: 15px; background: #fff7fa; }
.rule-notice > :deep(.el-icon) { flex: 0 0 auto; margin-top: 2px; color: #d85f89; font-size: 20px; }
.rule-notice strong { color: #4b3941; }
.rule-notice p { margin: 5px 0 0; color: #8e747e; font-size: 13px; line-height: 1.6; }
.full-width { width: 100%; }
.sample-box { padding: 16px; margin-top: 8px; border: 1px solid #eee2e6; border-radius: 16px; background: #fcfafb; }
.sample-heading { display: flex; flex-direction: column; gap: 4px; margin-bottom: 12px; }
.sample-heading strong { color: #4b3c42; }
.sample-heading span { color: #97828a; font-size: 12px; line-height: 1.5; }
.sample-result { display: flex; align-items: center; gap: 7px; margin-top: 10px; color: #57916f; font-size: 13px; }
.sample-result.matched { color: #d55274; }
.drawer-actions { display: flex; justify-content: flex-end; gap: 10px; }
small { color: #9b8790; }
</style>
