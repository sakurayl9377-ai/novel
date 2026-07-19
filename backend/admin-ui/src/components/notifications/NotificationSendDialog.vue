<script setup lang="ts">
import { Check, Lock, Promotion, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { ref, watch } from 'vue';

import { sendNotification } from '@/services/notifications';
import type {
  NotificationDetailResponse,
  NotificationSendResponse,
} from '@/types/notifications';
import { notificationAudienceLabel, notificationCategoryLabel } from '@/utils/notifications';

const props = defineProps<{
  modelValue: boolean;
  detail: NotificationDetailResponse | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  sent: [result: NotificationSendResponse];
}>();

const changeNote = ref('');
const acknowledged = ref(false);
const sending = ref(false);
const idempotencyKey = ref('');

watch(
  () => props.modelValue,
  (open) => {
    if (open) {
      changeNote.value = '';
      acknowledged.value = false;
      idempotencyKey.value = createIdempotencyKey();
    }
  },
);

async function confirmSend(): Promise<void> {
  const detail = props.detail;
  if (!detail) return;
  if (!acknowledged.value) {
    ElMessage.warning('请确认已核对消息内容和受众人数');
    return;
  }
  if (changeNote.value.trim().length < 4) {
    ElMessage.warning('请填写发送原因');
    return;
  }
  if (detail.preview.eligibleCount <= 0) {
    ElMessage.warning('当前受众没有可发送用户');
    return;
  }
  if (detail.preview.eligibleCount > detail.preview.maxRecipients) {
    ElMessage.error('受众人数超过单次发送上限');
    return;
  }
  sending.value = true;
  try {
    const result = await sendNotification(detail.item.id, {
      expectedRevision: detail.item.revision,
      idempotencyKey: idempotencyKey.value,
      changeNote: changeNote.value.trim(),
    });
    ElMessage.success(result.idempotent ? '已确认上一次发送结果' : `已写入 ${result.delivery.deliveredCount.toLocaleString()} 条站内消息`);
    emit('sent', result);
    emit('update:modelValue', false);
  } catch (error) {
    ElMessage.error(errorMessage(error, '通知发送失败，草稿仍保留'));
  } finally {
    sending.value = false;
  }
}

function createIdempotencyKey(): string {
  if (typeof crypto !== 'undefined' && 'randomUUID' in crypto) return crypto.randomUUID();
  return `admin-notice-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDialog
    :model-value="modelValue"
    title="确认发送站内消息"
    width="min(560px, 94vw)"
    :close-on-click-modal="false"
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template v-if="detail">
      <div class="send-dialog-body">
        <div class="send-message-preview"><span class="message-category">{{ notificationCategoryLabel(detail.item.category) }}</span><strong>{{ detail.item.title }}</strong><p>{{ detail.item.content }}</p></div>
        <div class="send-summary">
          <div><span>预计受众</span><strong>{{ detail.preview.eligibleCount.toLocaleString() }} 位</strong></div>
          <div><span>筛选条件</span><strong>{{ notificationAudienceLabel(detail.item.audience) }}</strong></div>
          <div><span>发送方式</span><strong>站内消息 · 原子写入</strong></div>
        </div>
        <ElAlert v-if="detail.preview.live" type="info" :closable="false" show-icon title="发送时会再次计算受众，人数可能与预览略有变化" />
        <ElAlert v-if="detail.item.audience.includeAdmins" type="warning" :closable="false" show-icon title="当前受众包含管理员账号" />
        <div class="ack-row"><ElCheckbox v-model="acknowledged"><ElIcon><Check /></ElIcon>我已核对标题、正文、受众条件和预计人数</ElCheckbox></div>
        <ElFormItem label="发送原因" required><ElInput v-model="changeNote" maxlength="500" show-word-limit placeholder="例如：发布已审核的版本维护提醒" /></ElFormItem>
        <div class="atomic-note"><ElIcon><Lock /></ElIcon><span>发送会在同一个数据库事务中完成。失败时不会留下半条通知，草稿会保留。</span></div>
      </div>
    </template>
    <ElEmpty v-else :image-size="54" description="没有可发送的通知" />
    <template #footer><ElButton @click="emit('update:modelValue', false)">返回</ElButton><ElButton type="primary" :icon="Promotion" :loading="sending" :disabled="!detail" @click="confirmSend">确认发送</ElButton></template>
  </ElDialog>
</template>

<style scoped>
.send-dialog-body { display: grid; gap: 13px; }
.send-message-preview { display: grid; gap: 7px; padding: 13px; border-left: 3px solid var(--sakura-500); background: #fff8fa; }
.message-category { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .06em; }
.send-message-preview strong { color: var(--ink-900); font-size: 15px; }
.send-message-preview p { margin: 0; color: var(--ink-700); font-size: 12px; line-height: 1.6; white-space: pre-wrap; }
.send-summary { display: grid; gap: 8px; padding: 12px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }
.send-summary div { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
.send-summary span { flex: 0 0 auto; color: var(--ink-500); font-size: 10px; }
.send-summary strong { min-width: 0; color: var(--ink-800); font-size: 11px; text-align: right; line-height: 1.5; }
.ack-row { padding: 9px 10px; border: 1px solid #ecd8df; border-radius: 7px; background: #fff9fb; }
.atomic-note { display: flex; align-items: flex-start; gap: 7px; color: var(--ink-500); font-size: 10px; line-height: 1.5; }
.atomic-note .el-icon { flex: 0 0 auto; color: #39769b; }
@media (max-width: 520px) {
  .send-summary div { display: grid; gap: 3px; }
  .send-summary strong { text-align: left; }
}
</style>
