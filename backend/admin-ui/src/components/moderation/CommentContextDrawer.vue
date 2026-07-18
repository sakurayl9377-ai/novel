<script setup lang="ts">
import {
  ChatLineRound,
  Delete,
  Document,
  Flag,
  RefreshLeft,
  User,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { getCommentContext, updateCommentStatus } from '@/services/moderation';
import type {
  CommentContextResponse,
  CommentItem,
  CommentStatus,
  ReportItem,
} from '@/types/moderation';
import { formatDateTime } from '@/utils/format';
import {
  commentStatusLabel,
  contentTargetLabel,
  reportStatusLabel,
  reportStatusTone,
} from '@/utils/moderation';

const props = defineProps<{
  modelValue: boolean;
  commentId: number | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'status-changed': [];
  'open-comment': [id: number];
  'open-report': [item: ReportItem];
}>();

const loading = ref(false);
const updating = ref(false);
const detail = ref<CommentContextResponse | null>(null);
const openPanels = ref<string[]>(['thread', 'reports']);

const sceneTitle = computed(() => {
  const target = detail.value?.target;
  if (!target) return '';
  return target.episodeTitle || target.chapterTitle || target.title || `${contentTargetLabel(target.type)} ${target.id}`;
});

watch(
  () => [props.modelValue, props.commentId] as const,
  ([open]) => {
    if (open && props.commentId) void loadDetail();
  },
);

async function loadDetail(): Promise<void> {
  if (!props.commentId) return;
  loading.value = true;
  try {
    detail.value = await getCommentContext(props.commentId);
  } catch (error) {
    ElMessage.error(errorMessage(error));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

async function changeStatus(status: CommentStatus): Promise<void> {
  if (!detail.value || updating.value) return;
  updating.value = true;
  try {
    const response = await updateCommentStatus(detail.value.item.id, status);
    detail.value.item = response.item;
    emit('status-changed');
    ElMessage.success(status === 'deleted' ? '评论已删除，前台将不再展示' : '评论已恢复展示');
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    updating.value = false;
  }
}

function openRelatedComment(item: CommentItem): void {
  if (item.id !== detail.value?.item.id) emit('open-comment', item.id);
}

function avatarLetter(item: CommentItem): string {
  return item.user.nickname?.trim().slice(0, 1) || String(item.user.id).slice(-1);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '评论上下文加载失败';
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="comment-context-drawer"
    size="min(760px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <div class="drawer-heading-icon"><ElIcon><ChatLineRound /></ElIcon></div>
        <div>
          <span class="eyebrow">CONVERSATION CONTEXT</span>
          <h2>评论上下文</h2>
          <p v-if="detail">评论 #{{ detail.item.id }} · {{ sceneTitle }}</p>
        </div>
      </div>
    </template>

    <div v-loading="loading" class="context-body">
      <template v-if="detail">
        <section class="scene-card">
          <div class="scene-icon"><ElIcon><Document /></ElIcon></div>
          <div>
            <span>{{ contentTargetLabel(detail.target.type) }}场景</span>
            <strong>{{ sceneTitle || '未记录内容标题' }}</strong>
            <small>
              {{ contentTargetLabel(detail.target.type) }} {{ detail.target.id }}
              <template v-if="detail.target.chapterId"> · 章节 {{ detail.target.chapterId }}</template>
              <template v-if="detail.target.episodeId"> · 剧集 {{ detail.target.episodeId }}</template>
            </small>
          </div>
        </section>

        <section class="focus-comment" :class="{ 'is-deleted': detail.item.status === 'deleted' }">
          <div class="comment-author">
            <span class="comment-avatar">{{ avatarLetter(detail.item) }}</span>
            <div>
              <strong>{{ detail.item.user.nickname || `用户 #${detail.item.user.id}` }}</strong>
              <small>用户 #{{ detail.item.user.id }} · {{ formatDateTime(detail.item.createdAt) }}</small>
            </div>
            <ElTag :type="detail.item.status === 'visible' ? 'success' : 'info'" effect="light">
              {{ commentStatusLabel(detail.item.status) }}
            </ElTag>
          </div>
          <p>{{ detail.item.content }}</p>
          <div class="comment-metrics">
            <span>点赞 {{ detail.item.likeCount }}</span>
            <span>回复 {{ detail.item.replyCount }}</span>
            <span v-if="detail.item.rating">评分 {{ detail.item.rating }}</span>
            <span v-if="detail.item.parentId">回复评论 #{{ detail.item.parentId }}</span>
          </div>
        </section>

        <div class="focus-actions">
          <template v-if="detail.item.status === 'visible'">
            <ElPopconfirm
              width="270"
              title="删除后前台不再展示，但仍保留审核记录。确定继续？"
              confirm-button-text="确认删除"
              cancel-button-text="取消"
              @confirm="changeStatus('deleted')"
            >
              <template #reference>
                <ElButton type="danger" plain :icon="Delete" :loading="updating">删除评论</ElButton>
              </template>
            </ElPopconfirm>
          </template>
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
          <ElCollapseItem name="thread">
            <template #title>
              <span class="collapse-title">
                <ElIcon><ChatLineRound /></ElIcon>
                对话线程
                <b>{{ detail.replies.length + (detail.parent ? 1 : 0) }}</b>
              </span>
            </template>
            <div v-if="!detail.parent && detail.replies.length === 0" class="compact-empty">
              这是一条独立评论，暂无上下文回复
            </div>
            <div v-else class="thread-list">
              <article v-if="detail.parent" class="related-comment">
                <div class="relation-label">上级评论</div>
                <div class="related-head">
                  <strong>{{ detail.parent.user.nickname || `用户 #${detail.parent.user.id}` }}</strong>
                  <time>{{ formatDateTime(detail.parent.createdAt) }}</time>
                </div>
                <p>{{ detail.parent.content }}</p>
                <ElButton link type="primary" @click="openRelatedComment(detail.parent)">打开这条评论</ElButton>
              </article>
              <article v-for="reply in detail.replies" :key="reply.id" class="related-comment">
                <div class="relation-label">回复 #{{ reply.id }}</div>
                <div class="related-head">
                  <strong>{{ reply.user.nickname || `用户 #${reply.user.id}` }}</strong>
                  <time>{{ formatDateTime(reply.createdAt) }}</time>
                </div>
                <p>{{ reply.content }}</p>
                <div class="related-foot">
                  <ElTag size="small" :type="reply.status === 'visible' ? 'success' : 'info'">
                    {{ commentStatusLabel(reply.status) }}
                  </ElTag>
                  <ElButton link type="primary" @click="openRelatedComment(reply)">打开这条评论</ElButton>
                </div>
              </article>
            </div>
          </ElCollapseItem>

          <ElCollapseItem name="reports">
            <template #title>
              <span class="collapse-title">
                <ElIcon><Flag /></ElIcon>
                关联举报
                <b>{{ detail.reports.length }}</b>
              </span>
            </template>
            <div v-if="detail.reports.length === 0" class="compact-empty">这条评论尚未收到举报</div>
            <div v-else class="report-list">
              <button
                v-for="report in detail.reports"
                :key="report.id"
                type="button"
                class="related-report"
                @click="emit('open-report', report)"
              >
                <span class="report-flag"><ElIcon><Flag /></ElIcon></span>
                <span>
                  <strong>{{ report.reason }}</strong>
                  <small>举报人：{{ report.reporter?.nickname || '匿名' }} · {{ formatDateTime(report.createdAt) }}</small>
                </span>
                <ElTag size="small" :type="reportStatusTone(report.status)">
                  {{ reportStatusLabel(report.status) }}
                </ElTag>
              </button>
            </div>
          </ElCollapseItem>

          <ElCollapseItem name="author">
            <template #title>
              <span class="collapse-title">
                <ElIcon><User /></ElIcon>
                作者信息
              </span>
            </template>
            <ElDescriptions :column="2" border>
              <ElDescriptionsItem label="用户昵称">{{ detail.item.user.nickname || '未设置' }}</ElDescriptionsItem>
              <ElDescriptionsItem label="用户 ID">{{ detail.item.user.id }}</ElDescriptionsItem>
              <ElDescriptionsItem label="评论 ID">{{ detail.item.id }}</ElDescriptionsItem>
              <ElDescriptionsItem label="内容状态">{{ commentStatusLabel(detail.item.status) }}</ElDescriptionsItem>
            </ElDescriptions>
          </ElCollapseItem>
        </ElCollapse>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading,
.comment-author,
.scene-card,
.related-head,
.related-foot,
.collapse-title {
  display: flex;
  align-items: center;
}

.drawer-heading {
  gap: 13px;
}

.drawer-heading-icon,
.scene-icon,
.report-flag {
  display: grid;
  place-items: center;
  color: var(--sakura-600);
  background: var(--sakura-50);
}

.drawer-heading-icon {
  width: 44px;
  height: 44px;
  border-radius: 14px;
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

.context-body {
  min-height: 360px;
  display: grid;
  align-content: start;
  gap: 14px;
}

.scene-card {
  gap: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 13px;
  background: var(--surface-muted);
}

.scene-icon {
  width: 38px;
  height: 38px;
  flex: 0 0 38px;
  border-radius: 12px;
}

.scene-card > div:last-child {
  min-width: 0;
  display: grid;
}

.scene-card span,
.scene-card small {
  color: var(--ink-500);
  font-size: 10px;
}

.scene-card strong {
  margin: 3px 0;
  overflow: hidden;
  color: var(--ink-900);
  font-size: 13px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.focus-comment {
  border: 1px solid var(--sakura-200);
  border-radius: 16px;
  padding: 18px;
  background: linear-gradient(145deg, white, var(--sakura-50));
}

.focus-comment.is-deleted {
  border-color: var(--line);
  background: var(--surface-muted);
}

.comment-author {
  gap: 10px;
}

.comment-avatar {
  width: 38px;
  height: 38px;
  flex: 0 0 38px;
  display: grid;
  place-items: center;
  border-radius: 12px;
  color: var(--sakura-600);
  background: var(--sakura-100);
  font-weight: 800;
}

.comment-author > div {
  min-width: 0;
  flex: 1;
  display: grid;
}

.comment-author strong {
  color: var(--ink-900);
  font-size: 13px;
}

.comment-author small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 10px;
}

.focus-comment > p {
  margin: 16px 0;
  color: var(--ink-900);
  font-size: 15px;
  line-height: 1.75;
  white-space: pre-wrap;
  word-break: break-word;
}

.comment-metrics {
  display: flex;
  flex-wrap: wrap;
  gap: 7px;
}

.comment-metrics span,
.relation-label {
  border-radius: 999px;
  padding: 4px 8px;
  color: var(--ink-500);
  background: white;
  font-size: 10px;
}

.focus-actions {
  display: flex;
  justify-content: flex-end;
}

.context-collapse {
  border-top: 0;
}

.collapse-title {
  gap: 8px;
  color: var(--ink-700);
  font-weight: 700;
}

.collapse-title b {
  min-width: 22px;
  border-radius: 999px;
  padding: 2px 7px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 10px;
  text-align: center;
}

.thread-list,
.report-list {
  display: grid;
  gap: 9px;
  padding-bottom: 12px;
}

.related-comment {
  border: 1px solid var(--line);
  border-radius: 13px;
  padding: 12px;
  background: var(--surface-muted);
}

.relation-label {
  width: fit-content;
  margin-bottom: 9px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-weight: 700;
}

.related-head,
.related-foot {
  justify-content: space-between;
  gap: 10px;
}

.related-head strong {
  color: var(--ink-900);
  font-size: 12px;
}

.related-head time {
  color: var(--ink-300);
  font-size: 10px;
}

.related-comment p {
  margin: 8px 0;
  color: var(--ink-700);
  font-size: 12px;
  line-height: 1.65;
  white-space: pre-wrap;
  word-break: break-word;
}

.related-report {
  min-width: 0;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 10px;
  border: 1px solid var(--line);
  border-radius: 13px;
  padding: 11px;
  text-align: left;
  color: inherit;
  background: white;
}

.related-report:hover {
  border-color: var(--sakura-200);
  background: var(--sakura-50);
}

.report-flag {
  width: 34px;
  height: 34px;
  border-radius: 11px;
}

.related-report > span:nth-child(2) {
  min-width: 0;
  display: grid;
}

.related-report strong,
.related-report small {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.related-report strong {
  color: var(--ink-900);
  font-size: 12px;
}

.related-report small {
  margin-top: 4px;
  color: var(--ink-500);
  font-size: 10px;
}

.compact-empty {
  border: 1px dashed var(--line);
  border-radius: 12px;
  padding: 20px;
  color: var(--ink-300);
  background: var(--surface-muted);
  font-size: 11px;
  text-align: center;
}

@media (max-width: 560px) {
  .focus-comment {
    padding: 14px;
  }

  .comment-author {
    align-items: flex-start;
    flex-wrap: wrap;
  }

  .comment-author .el-tag {
    margin-left: 48px;
  }

  .related-report {
    grid-template-columns: auto minmax(0, 1fr);
  }

  .related-report .el-tag {
    grid-column: 2;
    justify-self: start;
  }
}
</style>
