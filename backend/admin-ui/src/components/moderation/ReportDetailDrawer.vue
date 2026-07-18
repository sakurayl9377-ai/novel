<script setup lang="ts">
import {
  Check,
  Close,
  Delete,
  Flag,
  RefreshLeft,
  View,
  Warning,
} from '@element-plus/icons-vue';
import { computed } from 'vue';

import type { ReportItem, ReportStatus } from '@/types/moderation';
import { formatDateTime } from '@/utils/format';
import {
  destructiveReportAction,
  reportPreviewText,
  reportStatusLabel,
  reportStatusTone,
  reportTargetLabel,
} from '@/utils/moderation';

const props = defineProps<{
  modelValue: boolean;
  report: ReportItem | null;
  processing?: boolean;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'change-status': [status: ReportStatus];
  'delete-target': [];
  'open-comment': [id: number];
}>();

const isOpen = computed(() => props.report?.status === 'open');
const canDeleteTarget = computed(() => Boolean(props.report?.preview));
const destructiveAction = computed(() => props.report
  ? destructiveReportAction(props.report.targetType)
  : '删除目标并处理');

function commentTargetId(): number | null {
  if (props.report?.targetType !== 'comment') return null;
  const id = Number(props.report.targetId);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="report-detail-drawer"
    size="min(700px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <div class="drawer-heading-icon"><ElIcon><Flag /></ElIcon></div>
        <div>
          <span class="eyebrow">REPORT DECISION</span>
          <h2>举报 #{{ report?.id || '—' }}</h2>
          <p v-if="report">{{ reportTargetLabel(report.targetType) }} #{{ report.targetId }}</p>
        </div>
      </div>
    </template>

    <div v-if="report" class="report-detail-body">
      <section class="report-reason-card">
        <div class="reason-head">
          <span><ElIcon><Warning /></ElIcon>举报理由</span>
          <ElTag :type="reportStatusTone(report.status)" effect="light">
            {{ reportStatusLabel(report.status) }}
          </ElTag>
        </div>
        <p>{{ report.reason }}</p>
        <div class="reason-meta">
          <span>举报人：{{ report.reporter?.nickname || '匿名用户' }}</span>
          <span>{{ formatDateTime(report.createdAt) }}</span>
        </div>
      </section>

      <section class="target-preview" :class="{ 'is-missing': !report.preview }">
        <div class="preview-heading">
          <div>
            <span class="eyebrow">REPORTED TARGET</span>
            <h3>{{ reportTargetLabel(report.targetType) }}内容</h3>
          </div>
          <ElTag size="small" effect="plain">#{{ report.targetId }}</ElTag>
        </div>

        <template v-if="report.preview?.type === 'user'">
          <div class="user-preview">
            <span class="user-avatar">{{ report.preview.nickname.slice(0, 1) || report.preview.id }}</span>
            <div>
              <strong>{{ report.preview.nickname || `用户 #${report.preview.id}` }}</strong>
              <span>{{ report.preview.email }}</span>
              <small>角色 {{ report.preview.role }} · 状态 {{ report.preview.status }}</small>
            </div>
          </div>
        </template>
        <template v-else-if="report.preview">
          <blockquote>{{ reportPreviewText(report) }}</blockquote>
          <div class="preview-meta">
            <span>发布者：{{ report.preview.user.nickname || `用户 #${report.preview.user.id}` }}</span>
            <span>{{ formatDateTime(report.preview.createdAt) }}</span>
            <template v-if="report.preview.type === 'comment'">
              <span>{{ report.preview.targetType }} / {{ report.preview.targetId }}</span>
            </template>
            <template v-else-if="report.preview.type === 'danmaku'">
              <span>视频 {{ report.preview.videoId }} · {{ Math.round(report.preview.timeMs / 1000) }} 秒</span>
            </template>
            <template v-else>
              <span>房间 {{ report.preview.roomId }}</span>
            </template>
          </div>
        </template>
        <div v-else class="missing-target">
          <ElIcon><Delete /></ElIcon>
          <strong>目标内容已不存在</strong>
          <span>无需再次删除，可以直接将举报标记为已处理。</span>
        </div>

        <ElButton
          v-if="commentTargetId()"
          class="context-button"
          type="primary"
          plain
          :icon="View"
          @click="emit('open-comment', commentTargetId()!)"
        >查看完整评论上下文</ElButton>
      </section>

      <section v-if="report.handler || report.handledAt" class="handling-record">
        <span>最近处理记录</span>
        <strong>{{ report.handler?.nickname || '未知管理员' }}</strong>
        <time>{{ formatDateTime(report.handledAt) }}</time>
      </section>

      <section class="decision-panel">
        <div>
          <span class="eyebrow">DECISION</span>
          <h3>{{ isOpen ? '选择处置结果' : '该举报已完成处置' }}</h3>
          <p>{{ isOpen ? '只有确认违规时才删除目标；内容合规时可忽略并保留记录。' : '如需重新核查，可以将举报恢复到待处理队列。' }}</p>
        </div>

        <div v-if="isOpen" class="decision-actions">
          <ElButton type="primary" :icon="Check" :loading="processing" @click="emit('change-status', 'resolved')">
            保留目标并处理
          </ElButton>
          <ElButton :icon="Close" :loading="processing" @click="emit('change-status', 'ignored')">
            内容合规，忽略
          </ElButton>
          <ElPopconfirm
            width="310"
            :title="`${destructiveAction}后无法在此撤销，确定继续？`"
            confirm-button-text="确认执行"
            cancel-button-text="取消"
            @confirm="emit('delete-target')"
          >
            <template #reference>
              <ElButton
                type="danger"
                plain
                :icon="Delete"
                :loading="processing"
                :disabled="!canDeleteTarget"
              >{{ destructiveAction }}</ElButton>
            </template>
          </ElPopconfirm>
        </div>
        <ElButton
          v-else
          type="primary"
          plain
          :icon="RefreshLeft"
          :loading="processing"
          @click="emit('change-status', 'open')"
        >重新打开举报</ElButton>
      </section>
    </div>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading,
.reason-head,
.reason-meta,
.preview-heading,
.preview-meta,
.user-preview,
.handling-record {
  display: flex;
  align-items: center;
}

.drawer-heading {
  gap: 13px;
}

.drawer-heading-icon {
  width: 44px;
  height: 44px;
  display: grid;
  place-items: center;
  border-radius: 14px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 20px;
}

.drawer-heading h2,
.drawer-heading p {
  margin: 0;
}

.drawer-heading h2 {
  margin-top: 4px;
  font-size: 18px;
}

.drawer-heading p {
  margin-top: 4px;
  color: var(--ink-500);
  font-size: 11px;
}

.report-detail-body {
  display: grid;
  gap: 14px;
}

.report-reason-card,
.target-preview,
.decision-panel {
  border: 1px solid var(--line);
  border-radius: 16px;
  padding: 18px;
  background: white;
}

.report-reason-card {
  border-color: #f2d1b9;
  background: linear-gradient(145deg, #fff, #fff9f3);
}

.reason-head,
.preview-heading {
  justify-content: space-between;
  gap: 12px;
}

.reason-head > span {
  display: flex;
  align-items: center;
  gap: 6px;
  color: #a65b23;
  font-size: 12px;
  font-weight: 700;
}

.report-reason-card > p {
  margin: 16px 0;
  color: var(--ink-900);
  font-size: 15px;
  line-height: 1.7;
  white-space: pre-wrap;
  word-break: break-word;
}

.reason-meta,
.preview-meta {
  flex-wrap: wrap;
  gap: 7px 14px;
  color: var(--ink-500);
  font-size: 10px;
}

.target-preview.is-missing {
  background: var(--surface-muted);
}

.preview-heading h3,
.decision-panel h3,
.decision-panel p {
  margin: 0;
}

.preview-heading h3,
.decision-panel h3 {
  margin-top: 5px;
  color: var(--ink-900);
  font-size: 15px;
}

.target-preview blockquote {
  margin: 18px 0 13px;
  border-left: 3px solid var(--sakura-200);
  padding: 3px 0 3px 14px;
  color: var(--ink-900);
  font-size: 14px;
  line-height: 1.75;
  white-space: pre-wrap;
  word-break: break-word;
}

.user-preview {
  gap: 12px;
  margin-top: 18px;
}

.user-avatar {
  width: 48px;
  height: 48px;
  flex: 0 0 48px;
  display: grid;
  place-items: center;
  border-radius: 15px;
  color: var(--sakura-600);
  background: var(--sakura-100);
  font-weight: 800;
}

.user-preview > div {
  min-width: 0;
  display: grid;
}

.user-preview strong {
  color: var(--ink-900);
  font-size: 14px;
}

.user-preview span,
.user-preview small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 11px;
}

.context-button {
  margin-top: 16px;
}

.missing-target {
  min-height: 150px;
  display: grid;
  place-items: center;
  align-content: center;
  gap: 7px;
  color: var(--ink-300);
}

.missing-target .el-icon {
  font-size: 28px;
}

.missing-target strong {
  color: var(--ink-700);
  font-size: 13px;
}

.missing-target span {
  font-size: 11px;
}

.handling-record {
  gap: 10px;
  border: 1px solid var(--line);
  border-radius: 13px;
  padding: 12px 14px;
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 11px;
}

.handling-record strong {
  color: var(--ink-900);
}

.handling-record time {
  margin-left: auto;
}

.decision-panel {
  display: grid;
  gap: 16px;
}

.decision-panel p {
  margin-top: 6px;
  color: var(--ink-500);
  font-size: 11px;
  line-height: 1.6;
}

.decision-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

.decision-actions .el-button + .el-button {
  margin-left: 0;
}

@media (max-width: 560px) {
  .report-reason-card,
  .target-preview,
  .decision-panel {
    padding: 14px;
  }

  .decision-actions {
    display: grid;
  }

  .decision-actions .el-button {
    width: 100%;
  }

  .handling-record {
    align-items: flex-start;
    flex-direction: column;
  }

  .handling-record time {
    margin-left: 0;
  }
}
</style>
