<script setup lang="ts">
import { Bell, DocumentChecked, EditPen, Promotion, Refresh, SwitchButton } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { cancelNotification, getNotification } from '@/services/notifications';
import type {
  NotificationDetailResponse,
  NotificationItem,
} from '@/types/notifications';
import { formatDateTime } from '@/utils/format';
import {
  notificationActionLabel,
  notificationAudienceLabel,
  notificationCategoryLabel,
  notificationStatusLabel,
  notificationStatusTone,
} from '@/utils/notifications';

const props = defineProps<{
  modelValue: boolean;
  notificationId: number;
  refreshKey?: number;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  edit: [item: NotificationItem];
  send: [detail: NotificationDetailResponse];
  canceled: [detail: NotificationDetailResponse];
}>();

const loading = ref(false);
const detail = ref<NotificationDetailResponse | null>(null);
const cancelNote = ref('');
const canceling = ref(false);
const cancelDialogOpen = ref(false);
const auditOpen = ref<string[]>([]);

const canMutate = computed(() => detail.value?.item.status === 'draft' || detail.value?.item.status === 'failed');

watch(
  () => [props.modelValue, props.notificationId, props.refreshKey],
  ([open]) => {
    if (open && props.notificationId) void loadDetail();
  },
  { immediate: true },
);

async function loadDetail(): Promise<void> {
  loading.value = true;
  try {
    detail.value = await getNotification(props.notificationId);
  } catch (error) {
    ElMessage.error(errorMessage(error, '通知详情加载失败'));
  } finally {
    loading.value = false;
  }
}

function openCancel(): void {
  cancelNote.value = '';
  cancelDialogOpen.value = true;
}

async function confirmCancel(): Promise<void> {
  const item = detail.value?.item;
  if (!item) return;
  if (cancelNote.value.trim().length < 4) {
    ElMessage.warning('请填写取消原因');
    return;
  }
  canceling.value = true;
  try {
    const result = await cancelNotification(item.id, {
      expectedRevision: item.revision,
      changeNote: cancelNote.value.trim(),
    });
    detail.value = result;
    cancelDialogOpen.value = false;
    ElMessage.success('通知草稿已取消');
    emit('canceled', result);
  } catch (error) {
    ElMessage.error(errorMessage(error, '取消通知失败'));
  } finally {
    canceling.value = false;
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(680px, 97vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="detail" class="detail-heading">
        <div class="heading-topline"><span class="eyebrow">NOTIFICATION RECORD #{{ detail.item.id }}</span><ElTag :type="notificationStatusTone(detail.item.status)" effect="plain">{{ notificationStatusLabel(detail.item.status) }}</ElTag></div>
        <h2>{{ detail.item.title }}</h2>
        <p>{{ notificationCategoryLabel(detail.item.category) }} · 修订号 {{ detail.item.revision }}</p>
      </div>
      <span v-else>通知详情</span>
    </template>

    <div v-loading="loading" class="notification-detail-body">
      <template v-if="detail">
        <section class="detail-block message-preview-block">
          <header><div><span class="block-eyebrow">MESSAGE</span><h3>用户端消息内容</h3></div><ElIcon><Bell /></ElIcon></header>
          <div class="message-preview"><strong>{{ detail.item.title }}</strong><p>{{ detail.item.content }}</p><small>{{ formatDateTime(detail.item.createdAt) }}</small></div>
        </section>

        <section class="detail-block">
          <header><div><span class="block-eyebrow">AUDIENCE</span><h3>受众快照</h3></div><ElTag type="info" effect="plain">{{ detail.preview.eligibleCount.toLocaleString() }} 位</ElTag></header>
          <div class="audience-detail"><strong>{{ notificationAudienceLabel(detail.item.audience) }}</strong><small v-if="detail.item.audience.legacy">历史记录没有保存旧版受众条件，人数以发送时记录为准</small><small v-else>{{ detail.preview.live ? '当前为实时估算，发送时会再次核验' : '人数为发送时保存的受众估算' }}</small></div>
          <div v-if="detail.preview.sample.length" class="detail-samples"><span v-for="sample in detail.preview.sample" :key="sample.id">{{ sample.nickname || `用户 #${sample.id}` }} · {{ sample.platform }}</span></div>
        </section>

        <section class="delivery-grid">
          <article><span>尝试发送</span><strong>{{ detail.delivery.attemptedCount.toLocaleString() }}</strong><small>受众记录</small></article>
          <article><span>已写入消息</span><strong>{{ detail.delivery.deliveredCount.toLocaleString() }}</strong><small>原子写入</small></article>
          <article><span>未读消息</span><strong>{{ detail.delivery.unreadCount.toLocaleString() }}</strong><small>用户端状态</small></article>
          <article><span>发送时间</span><strong>{{ detail.item.sentAt ? formatDateTime(detail.item.sentAt) : '未发送' }}</strong><small>{{ detail.item.operator?.nickname || '—' }}</small></article>
        </section>

        <ElCollapse v-model="auditOpen" class="audit-collapse">
          <ElCollapseItem name="events">
            <template #title><div class="collapse-title"><div><strong>变更与发送记录</strong><small>每次草稿修改、发送和取消都保留原因</small></div><ElTag type="success" effect="plain"><ElIcon><DocumentChecked /></ElIcon>已审计</ElTag></div></template>
            <div class="event-list">
              <article v-for="event in detail.events" :key="event.id" class="event-row">
                <span class="event-icon"><ElIcon><Promotion v-if="event.action === 'sent'" /><SwitchButton v-else-if="event.action === 'canceled'" /><EditPen v-else /></ElIcon></span>
                <div><strong>{{ notificationActionLabel(event.action) }}</strong><small>{{ event.operator?.nickname || '系统' }} · {{ formatDateTime(event.createdAt) }}</small><p>{{ event.note }}</p></div>
              </article>
              <ElEmpty v-if="!detail.events.length" :image-size="48" description="暂无审计事件" />
            </div>
          </ElCollapseItem>
        </ElCollapse>
      </template>
      <ElEmpty v-else-if="!loading" :image-size="56" description="暂无通知详情" />
    </div>

    <template #footer>
      <div v-if="detail" class="drawer-footer">
        <span class="footer-hint">{{ detail.item.status === 'sent' ? '已发送记录不可修改' : '草稿可以继续编辑或取消' }}</span>
        <div class="detail-actions">
          <ElButton v-if="canMutate" :icon="EditPen" @click="emit('edit', detail!.item)">编辑草稿</ElButton>
          <ElButton v-if="canMutate" type="primary" :icon="Promotion" @click="emit('send', detail!)">发送</ElButton>
          <ElButton v-if="canMutate" type="danger" plain :icon="SwitchButton" @click="openCancel">取消发送</ElButton>
        </div>
      </div>
    </template>
  </ElDrawer>

  <ElDialog v-model="cancelDialogOpen" title="取消通知草稿" width="min(460px, 92vw)">
    <p class="dialog-copy">取消后不会创建任何用户端消息，当前草稿仍会保留在历史记录中。</p>
    <ElInput v-model="cancelNote" type="textarea" :rows="4" maxlength="500" show-word-limit placeholder="填写取消原因" />
    <template #footer><ElButton @click="cancelDialogOpen = false">返回</ElButton><ElButton type="danger" :loading="canceling" @click="confirmCancel">确认取消</ElButton></template>
  </ElDialog>
</template>

<style scoped>
.detail-heading { display: grid; gap: 5px; }
.heading-topline { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.eyebrow, .block-eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.detail-heading h2 { margin: 0; overflow: hidden; color: var(--ink-900); font-size: 20px; text-overflow: ellipsis; white-space: nowrap; }
.detail-heading p { margin: 0; color: var(--ink-500); font-size: 11px; }
.notification-detail-body { display: grid; gap: 14px; min-height: 240px; }
.detail-block { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.detail-block > header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 11px; }
.detail-block > header > div { display: grid; gap: 3px; }
.detail-block > header .el-icon { color: var(--sakura-500); font-size: 18px; }
.detail-block h3 { margin: 0; color: var(--ink-900); font-size: 13px; }
.message-preview { padding: 13px; border-left: 3px solid var(--sakura-500); background: #fff8fa; }
.message-preview strong { color: var(--ink-900); font-size: 14px; }
.message-preview p { margin: 8px 0; color: var(--ink-700); font-size: 12px; line-height: 1.7; white-space: pre-wrap; }
.message-preview small { color: var(--ink-500); font-size: 10px; }
.audience-detail { display: grid; gap: 5px; }
.audience-detail strong { color: var(--ink-800); font-size: 12px; line-height: 1.5; }
.audience-detail small { color: var(--ink-500); font-size: 10px; }
.detail-samples { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 12px; }
.detail-samples span { padding: 5px 8px; border-radius: 5px; color: #52687a; background: #eef4f8; font-size: 10px; }
.delivery-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.delivery-grid article { min-width: 0; display: grid; gap: 4px; padding: 12px; border-right: 1px solid var(--line); }
.delivery-grid article:last-child { border-right: 0; }
.delivery-grid span, .delivery-grid small { color: var(--ink-500); font-size: 10px; }
.delivery-grid strong { overflow: hidden; color: var(--ink-900); font-size: 15px; text-overflow: ellipsis; white-space: nowrap; }
.audit-collapse { border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.audit-collapse :deep(.el-collapse-item__header) { min-height: 56px; height: auto; padding: 8px 14px; }
.audit-collapse :deep(.el-collapse-item__content) { padding: 0 14px 14px; }
.collapse-title { width: calc(100% - 18px); display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.collapse-title > div { display: grid; gap: 3px; }
.collapse-title strong { color: var(--ink-900); font-size: 12px; }
.collapse-title small { color: var(--ink-500); font-size: 9px; }
.event-list { display: grid; gap: 8px; }
.event-row { display: flex; gap: 9px; padding: 9px 0; border-bottom: 1px solid var(--line); }
.event-row:last-child { border-bottom: 0; }
.event-icon { width: 27px; height: 27px; flex: 0 0 27px; display: grid; place-items: center; border-radius: 6px; color: var(--sakura-600); background: var(--sakura-50); }
.event-row > div { min-width: 0; display: grid; gap: 3px; }
.event-row strong { color: var(--ink-800); font-size: 11px; }
.event-row small { color: var(--ink-500); font-size: 9px; }
.event-row p { margin: 3px 0 0; color: var(--ink-600); font-size: 10px; line-height: 1.5; }
.drawer-footer { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.footer-hint { color: var(--ink-500); font-size: 10px; }
.detail-actions { display: flex; gap: 7px; }
.dialog-copy { margin: 0 0 12px; color: var(--ink-600); font-size: 12px; line-height: 1.6; }
@media (max-width: 560px) {
  .delivery-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .delivery-grid article:nth-child(2) { border-right: 0; }
  .delivery-grid article:nth-child(-n + 2) { border-bottom: 1px solid var(--line); }
  .drawer-footer { align-items: flex-end; flex-direction: column; }
  .detail-actions { flex-wrap: wrap; justify-content: flex-end; }
}
</style>
