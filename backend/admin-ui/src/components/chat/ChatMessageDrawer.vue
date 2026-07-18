<script setup lang="ts">
import {
  ChatLineRound,
  Clock,
  Delete,
  Document,
  Flag,
  RefreshLeft,
  User,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { getChatMessageContext, updateChatMessageStatus } from '@/services/chat';
import type { ChatMessage, ChatMessageContextResponse, ChatMessageStatus } from '@/types/chat';
import type { ReportItem } from '@/types/moderation';
import {
  chatMessageStatusLabel,
  chatMessageTypeLabel,
} from '@/utils/chat';
import { formatDateTime } from '@/utils/format';
import { reportStatusLabel, reportStatusTone } from '@/utils/moderation';

const props = defineProps<{
  modelValue: boolean;
  messageId: number | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'status-changed': [];
  'open-message': [id: number];
  'open-report': [item: ReportItem];
}>();

const loading = ref(false);
const updating = ref(false);
const detail = ref<ChatMessageContextResponse | null>(null);
const openPanels = ref<string[]>(['nearby', 'reports']);

const metadataEntries = computed(() => Object.entries(detail.value?.item.metadata || {})
  .filter(([, value]) => value !== null && value !== '' && value !== false));

watch(
  () => [props.modelValue, props.messageId] as const,
  ([open]) => {
    if (open && props.messageId) void loadDetail();
  },
);

async function loadDetail(): Promise<void> {
  if (!props.messageId) return;
  loading.value = true;
  try {
    detail.value = await getChatMessageContext(props.messageId);
  } catch (error) {
    ElMessage.error(errorMessage(error, '消息上下文加载失败'));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

async function changeStatus(status: ChatMessageStatus): Promise<void> {
  if (!detail.value || updating.value) return;
  updating.value = true;
  try {
    await updateChatMessageStatus(detail.value.item.id, status);
    detail.value.item.status = status;
    emit('status-changed');
    ElMessage.success(status === 'deleted' ? '消息已删除，客户端不再展示' : '消息已恢复展示');
  } catch (error) {
    ElMessage.error(errorMessage(error, '消息状态更新失败'));
  } finally {
    updating.value = false;
  }
}

function relativeTime(item: ChatMessage): string {
  if (!detail.value) return '';
  const delta = Math.round(
    (new Date(item.createdAt).getTime() - new Date(detail.value.item.createdAt).getTime()) / 1000,
  );
  if (!Number.isFinite(delta) || delta === 0) return '同一时刻';
  const amount = Math.abs(delta);
  return delta > 0 ? `晚 ${amount} 秒` : `早 ${amount} 秒`;
}

function metadataText(value: unknown): string {
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    size="min(760px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <div class="drawer-icon"><ElIcon><ChatLineRound /></ElIcon></div>
        <div>
          <span>MESSAGE CONTEXT</span>
          <h2>消息审核上下文</h2>
          <p v-if="detail">{{ detail.room.name }} · {{ detail.room.roomId }}</p>
        </div>
      </div>
    </template>

    <div v-loading="loading" class="message-context-body">
      <template v-if="detail">
        <section class="room-strip">
          <div class="room-avatar">
            <img v-if="detail.room.avatarUrl" :src="detail.room.avatarUrl" alt="" />
            <span v-else>{{ detail.room.name.slice(0, 1) }}</span>
          </div>
          <div>
            <strong>{{ detail.room.name }}</strong>
            <span>{{ detail.room.categoryLabel }} · Lv.{{ detail.room.minLevel }} 准入</span>
          </div>
          <ElTag :type="detail.room.status === 'active' ? 'success' : 'info'">
            {{ detail.room.status === 'active' ? '开放中' : '已隐藏' }}
          </ElTag>
        </section>

        <section class="focus-message" :class="{ deleted: detail.item.status === 'deleted' }">
          <div class="message-topline">
            <ElTag effect="plain">{{ chatMessageTypeLabel(detail.item.type) }}</ElTag>
            <ElTag :type="detail.item.status === 'visible' ? 'success' : 'info'">
              {{ chatMessageStatusLabel(detail.item.status) }}
            </ElTag>
            <span><ElIcon><Clock /></ElIcon>{{ formatDateTime(detail.item.createdAt) }}</span>
          </div>
          <blockquote>{{ detail.item.content }}</blockquote>

          <div v-if="detail.item.mediaUrl" class="media-preview">
            <img
              v-if="detail.item.type === 'image' || detail.item.type === 'sticker'"
              :src="detail.item.mediaUrl"
              alt="消息图片"
            />
            <audio v-else-if="detail.item.type === 'audio'" :src="detail.item.mediaUrl" controls />
            <a v-else :href="detail.item.mediaUrl" target="_blank" rel="noreferrer">
              <ElIcon><Document /></ElIcon>打开消息附件
            </a>
          </div>

          <div class="author-row">
            <ElAvatar :src="detail.item.user.avatarUrl" :size="40">
              {{ detail.item.user.nickname?.slice(0, 1) || detail.item.user.id }}
            </ElAvatar>
            <div>
              <strong>{{ detail.item.user.nickname || `用户 #${detail.item.user.id}` }}</strong>
              <span>UID {{ detail.item.user.id }} · 消息 #{{ detail.item.id }}</span>
            </div>
          </div>
        </section>

        <div class="focus-actions">
          <ElPopconfirm
            v-if="detail.item.status === 'visible'"
            width="280"
            title="删除后客户端不再展示，但审核记录仍会保留。确定继续？"
            confirm-button-text="确认删除"
            cancel-button-text="取消"
            @confirm="changeStatus('deleted')"
          >
            <template #reference>
              <ElButton type="danger" plain :icon="Delete" :loading="updating">删除消息</ElButton>
            </template>
          </ElPopconfirm>
          <ElButton
            v-else
            type="primary"
            plain
            :icon="RefreshLeft"
            :loading="updating"
            @click="changeStatus('visible')"
          >恢复展示</ElButton>
        </div>

        <ElCollapse v-model="openPanels" class="context-collapse">
          <ElCollapseItem name="nearby">
            <template #title>
              <span class="collapse-title"><ElIcon><Clock /></ElIcon>同房间相邻消息<b>{{ detail.nearby.length }}</b></span>
            </template>
            <div v-if="!detail.nearby.length" class="compact-empty">没有其他相邻消息</div>
            <div v-else class="nearby-list">
              <button
                v-for="item in detail.nearby"
                :key="item.id"
                type="button"
                class="nearby-item"
                @click="emit('open-message', item.id)"
              >
                <ElAvatar :src="item.user.avatarUrl" :size="34">
                  {{ item.user.nickname?.slice(0, 1) }}
                </ElAvatar>
                <span class="nearby-copy">
                  <strong>{{ item.content || `[${chatMessageTypeLabel(item.type)}]` }}</strong>
                  <small>{{ item.user.nickname || `用户 #${item.user.id}` }} · {{ relativeTime(item) }}</small>
                </span>
                <ElTag v-if="item.status === 'deleted'" size="small" type="info">已删除</ElTag>
              </button>
            </div>
          </ElCollapseItem>

          <ElCollapseItem name="reports">
            <template #title>
              <span class="collapse-title"><ElIcon><Flag /></ElIcon>关联举报<b>{{ detail.reports.length }}</b></span>
            </template>
            <div v-if="!detail.reports.length" class="compact-empty">这条消息没有关联举报</div>
            <div v-else class="report-list">
              <button
                v-for="report in detail.reports"
                :key="report.id"
                type="button"
                @click="emit('open-report', report)"
              >
                <span class="report-icon"><ElIcon><Flag /></ElIcon></span>
                <span class="report-copy">
                  <strong>{{ report.reason }}</strong>
                  <small>{{ report.reporter?.nickname || '匿名用户' }} · {{ formatDateTime(report.createdAt) }}</small>
                </span>
                <ElTag :type="reportStatusTone(report.status)" size="small">{{ reportStatusLabel(report.status) }}</ElTag>
              </button>
            </div>
          </ElCollapseItem>

          <ElCollapseItem v-if="metadataEntries.length" name="metadata">
            <template #title>
              <span class="collapse-title"><ElIcon><User /></ElIcon>消息附加信息<b>{{ metadataEntries.length }}</b></span>
            </template>
            <dl class="metadata-list">
              <template v-for="entry in metadataEntries" :key="entry[0]">
                <dt>{{ entry[0] }}</dt>
                <dd>{{ metadataText(entry[1]) }}</dd>
              </template>
            </dl>
          </ElCollapseItem>
        </ElCollapse>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading { display: flex; align-items: center; gap: 13px; }
.drawer-icon { display: grid; width: 46px; height: 46px; place-items: center; border-radius: 15px; color: #cf5b85; background: linear-gradient(135deg, #ffe3ed, #fff2dc); }
.drawer-icon :deep(.el-icon) { font-size: 23px; }
.drawer-heading span { color: #c46a87; font-size: 10px; font-weight: 800; letter-spacing: .12em; }
.drawer-heading h2 { margin: 2px 0; color: #3c3035; font-size: 20px; }
.drawer-heading p { margin: 0; color: #938088; font-size: 12px; }
.message-context-body { min-height: 280px; }
.room-strip { display: flex; align-items: center; gap: 12px; padding: 13px 15px; border: 1px solid #f0e2e7; border-radius: 16px; background: #fcfafb; }
.room-strip > div:nth-child(2) { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }
.room-strip strong { color: #48383f; }
.room-strip span { color: #96828a; font-size: 12px; }
.room-avatar { display: grid; width: 42px; height: 42px; overflow: hidden; place-items: center; border-radius: 13px; color: #bd6584; background: #ffe5ee; font-weight: 800; }
.room-avatar img { width: 100%; height: 100%; object-fit: cover; }
.focus-message { padding: 20px; margin-top: 16px; border: 1px solid #f1dce4; border-radius: 20px; background: linear-gradient(145deg, #fffafd, #fffdf9); }
.focus-message.deleted { opacity: .68; background: #f7f5f6; }
.message-topline { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
.message-topline > span { display: inline-flex; align-items: center; gap: 5px; margin-left: auto; color: #9a858d; font-size: 12px; }
.focus-message blockquote { margin: 18px 0; color: #362b30; font-size: 18px; font-weight: 620; line-height: 1.75; white-space: pre-wrap; }
.media-preview { margin: 12px 0 18px; }
.media-preview img { display: block; max-width: min(100%, 420px); max-height: 360px; border-radius: 16px; object-fit: contain; background: #f4eff1; }
.media-preview audio { width: min(100%, 420px); }
.media-preview a { display: inline-flex; align-items: center; gap: 7px; color: #c5527d; }
.author-row { display: flex; align-items: center; gap: 11px; padding-top: 14px; border-top: 1px dashed #eadde2; }
.author-row > div { display: flex; flex-direction: column; gap: 3px; }
.author-row strong { color: #4b3c42; }
.author-row span { color: #99858c; font-size: 12px; }
.focus-actions { display: flex; justify-content: flex-end; margin: 13px 0 8px; }
.context-collapse { margin-top: 10px; }
.collapse-title { display: inline-flex; align-items: center; gap: 8px; color: #55444b; font-weight: 650; }
.collapse-title b { display: grid; min-width: 20px; height: 20px; padding: 0 5px; place-items: center; border-radius: 10px; color: #c05a7d; background: #fde7ef; font-size: 11px; }
.compact-empty { padding: 22px; color: #9c8990; text-align: center; border-radius: 13px; background: #faf7f8; }
.nearby-list, .report-list { display: grid; gap: 8px; }
.nearby-item, .report-list button { display: flex; width: 100%; align-items: center; gap: 10px; padding: 11px 12px; border: 1px solid #f0e4e8; border-radius: 13px; color: inherit; text-align: left; background: #fff; cursor: pointer; }
.nearby-item:hover, .report-list button:hover { border-color: #e8bccc; background: #fff8fb; }
.nearby-copy, .report-copy { display: flex; flex: 1; flex-direction: column; gap: 3px; min-width: 0; }
.nearby-item strong, .report-list strong { overflow: hidden; color: #4b3b42; text-overflow: ellipsis; white-space: nowrap; }
.nearby-item small, .report-list small { color: #99858d; }
.report-icon { display: grid; width: 34px; height: 34px; place-items: center; border-radius: 11px; color: #d36486; background: #ffe8ef; }
.metadata-list { display: grid; grid-template-columns: 140px 1fr; gap: 8px 14px; margin: 0; }
.metadata-list dt { color: #8b747d; font-size: 12px; }
.metadata-list dd { margin: 0; overflow-wrap: anywhere; color: #514148; font-size: 12px; }

@media (max-width: 560px) {
  .message-topline > span { width: 100%; margin-left: 0; }
  .metadata-list { grid-template-columns: 1fr; gap: 3px; }
  .metadata-list dd { margin-bottom: 8px; }
}
</style>
