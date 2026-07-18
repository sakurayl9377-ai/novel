<script setup lang="ts">
import {
  Clock,
  Connection,
  Delete,
  Flag,
  RefreshLeft,
  VideoCamera,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, ref, watch } from 'vue';

import { getDanmakuContext, updateDanmakuStatus } from '@/services/danmaku';
import type {
  DanmakuContextResponse,
  DanmakuItem,
  DanmakuStatus,
} from '@/types/danmaku';
import type { ReportItem } from '@/types/moderation';
import { danmakuModeLabel, danmakuStatusLabel, formatTimecode } from '@/utils/danmaku';
import { formatDateTime } from '@/utils/format';
import { reportStatusLabel, reportStatusTone } from '@/utils/moderation';

const props = defineProps<{
  modelValue: boolean;
  danmakuId: number | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
  'status-changed': [];
  'open-danmaku': [id: number];
  'open-report': [item: ReportItem];
}>();

const loading = ref(false);
const updating = ref(false);
const detail = ref<DanmakuContextResponse | null>(null);
const openPanels = ref<string[]>(['nearby', 'sources', 'reports']);

const title = computed(() => detail.value
  ? `${detail.value.group.animeTitle} · ${detail.value.group.episodeTitle}`
  : '弹幕上下文');

watch(
  () => [props.modelValue, props.danmakuId] as const,
  ([open]) => {
    if (open && props.danmakuId) void loadDetail();
  },
);

async function loadDetail(): Promise<void> {
  if (!props.danmakuId) return;
  loading.value = true;
  try {
    detail.value = await getDanmakuContext(props.danmakuId);
  } catch (error) {
    ElMessage.error(errorMessage(error));
    emit('update:modelValue', false);
  } finally {
    loading.value = false;
  }
}

async function changeStatus(status: DanmakuStatus): Promise<void> {
  if (!detail.value || updating.value) return;
  updating.value = true;
  try {
    const response = await updateDanmakuStatus(detail.value.item.id, status);
    detail.value.item = response.item;
    emit('status-changed');
    ElMessage.success(status === 'deleted' ? '弹幕已删除，客户端不再展示' : '弹幕已恢复展示');
  } catch (error) {
    ElMessage.error(errorMessage(error));
  } finally {
    updating.value = false;
  }
}

function offsetLabel(item: DanmakuItem): string {
  if (!detail.value) return '';
  const seconds = Math.round((item.timeMs - detail.value.item.timeMs) / 1000);
  if (seconds === 0) return '同一时间点';
  return seconds > 0 ? `晚 ${seconds} 秒` : `早 ${Math.abs(seconds)} 秒`;
}

function openNearby(item: DanmakuItem): void {
  emit('open-danmaku', item.id);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : '弹幕上下文加载失败';
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="danmaku-context-drawer"
    size="min(760px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div class="drawer-heading">
        <div class="drawer-heading-icon"><ElIcon><VideoCamera /></ElIcon></div>
        <div>
          <span class="eyebrow">PLAYBACK CONTEXT</span>
          <h2>弹幕上下文</h2>
          <p>{{ title }}</p>
        </div>
      </div>
    </template>

    <div v-loading="loading" class="context-body">
      <template v-if="detail">
        <section class="episode-card">
          <div class="episode-icon"><ElIcon><VideoCamera /></ElIcon></div>
          <div>
            <span>{{ detail.group.animeTitle }}</span>
            <strong>{{ detail.group.episodeTitle }}</strong>
            <small>{{ detail.group.videoId }}</small>
          </div>
          <div class="episode-stats">
            <span><b>{{ detail.group.aliasCount }}</b> 播放源</span>
            <span v-if="detail.group.bilibiliImportedCount"><b>{{ detail.group.bilibiliImportedCount }}</b> 历史导入</span>
          </div>
        </section>

        <section class="focus-danmaku" :class="{ 'is-deleted': detail.item.status === 'deleted' }">
          <div class="focus-topline">
            <span class="timecode"><ElIcon><Clock /></ElIcon>{{ formatTimecode(detail.item.timeMs) }}</span>
            <span class="color-chip"><i :style="{ backgroundColor: detail.item.color }" />{{ detail.item.color }}</span>
            <ElTag v-if="detail.item.isImported" type="primary" effect="light">历史导入</ElTag>
            <ElTag :type="detail.item.status === 'visible' ? 'success' : 'info'" effect="light">
              {{ danmakuStatusLabel(detail.item.status) }}
            </ElTag>
          </div>
          <blockquote>{{ detail.item.content }}</blockquote>
          <div class="author-row">
            <span class="mini-avatar">{{ detail.item.user.nickname?.slice(0, 1) || detail.item.user.id }}</span>
            <span>
              <strong>{{ detail.item.user.nickname || `用户 #${detail.item.user.id}` }}</strong>
              <small>UID {{ detail.item.user.id }} · {{ danmakuModeLabel(detail.item.mode) }} · {{ formatDateTime(detail.item.createdAt) }}</small>
            </span>
          </div>
        </section>

        <div class="focus-actions">
          <ElPopconfirm
            v-if="detail.item.status === 'visible'"
            width="280"
            title="删除后客户端不再展示，但审核记录会保留。确定继续？"
            confirm-button-text="确认删除"
            cancel-button-text="取消"
            @confirm="changeStatus('deleted')"
          >
            <template #reference>
              <ElButton type="danger" plain :icon="Delete" :loading="updating">删除弹幕</ElButton>
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
              <span class="collapse-title">
                <ElIcon><Clock /></ElIcon>前后 15 秒同屏弹幕<b>{{ detail.nearby.length }}</b>
              </span>
            </template>
            <div v-if="detail.nearby.length === 0" class="compact-empty">该时间段没有其他弹幕</div>
            <div v-else class="nearby-list">
              <button
                v-for="item in detail.nearby"
                :key="item.id"
                type="button"
                class="nearby-item"
                @click="openNearby(item)"
              >
                <time>{{ formatTimecode(item.timeMs) }}</time>
                <span>
                  <strong>{{ item.content }}</strong>
                  <small>{{ item.user.nickname || `用户 #${item.user.id}` }} · {{ offsetLabel(item) }}</small>
                </span>
                <ElTag v-if="item.isImported" size="small" effect="plain">导入</ElTag>
                <ElTag v-else-if="item.status === 'deleted'" size="small" type="info">已删除</ElTag>
              </button>
            </div>
          </ElCollapseItem>

          <ElCollapseItem name="sources">
            <template #title>
              <span class="collapse-title">
                <ElIcon><Connection /></ElIcon>播放源绑定<b>{{ detail.aliases.length }}</b>
              </span>
            </template>
            <div v-if="detail.aliases.length === 0" class="compact-empty">当前剧集没有播放源别名</div>
            <div v-else class="alias-list">
              <article v-for="alias in detail.aliases" :key="alias.aliasVideoId">
                <span class="alias-icon"><ElIcon><Connection /></ElIcon></span>
                <span>
                  <strong>{{ alias.sourceName || '未命名来源' }}</strong>
                  <small>{{ alias.aliasVideoId }}</small>
                </span>
              </article>
            </div>
          </ElCollapseItem>

          <ElCollapseItem name="reports">
            <template #title>
              <span class="collapse-title">
                <ElIcon><Flag /></ElIcon>关联举报<b>{{ detail.reports.length }}</b>
              </span>
            </template>
            <div v-if="detail.reports.length === 0" class="compact-empty">这条弹幕尚未收到举报</div>
            <div v-else class="report-list">
              <button
                v-for="report in detail.reports"
                :key="report.id"
                type="button"
                class="related-report"
                @click="emit('open-report', report)"
              >
                <span class="report-icon"><ElIcon><Flag /></ElIcon></span>
                <span>
                  <strong>{{ report.reason }}</strong>
                  <small>举报人：{{ report.reporter?.nickname || '匿名' }} · {{ formatDateTime(report.createdAt) }}</small>
                </span>
                <ElTag size="small" :type="reportStatusTone(report.status)">{{ reportStatusLabel(report.status) }}</ElTag>
              </button>
            </div>
          </ElCollapseItem>
        </ElCollapse>
      </template>
    </div>
  </ElDrawer>
</template>

<style scoped>
.drawer-heading,
.episode-card,
.focus-topline,
.author-row,
.collapse-title,
.alias-list article {
  display: flex;
  align-items: center;
}

.drawer-heading {
  gap: 13px;
}

.drawer-heading-icon,
.episode-icon,
.alias-icon,
.report-icon {
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

.episode-card {
  gap: 12px;
  border: 1px solid var(--line);
  border-radius: 14px;
  padding: 13px;
  background: var(--surface-muted);
}

.episode-icon {
  width: 40px;
  height: 40px;
  flex: 0 0 40px;
  border-radius: 12px;
}

.episode-card > div:nth-child(2) {
  min-width: 0;
  flex: 1;
  display: grid;
}

.episode-card span,
.episode-card small {
  color: var(--ink-500);
  font-size: 10px;
}

.episode-card strong {
  margin: 3px 0;
  overflow: hidden;
  color: var(--ink-900);
  font-size: 13px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.episode-stats {
  display: flex;
  gap: 7px;
}

.episode-stats span {
  display: grid;
  justify-items: center;
  border-radius: 10px;
  padding: 7px 9px;
  background: white;
}

.episode-stats b {
  color: var(--ink-900);
  font-size: 14px;
}

.focus-danmaku {
  border: 1px solid var(--sakura-200);
  border-radius: 16px;
  padding: 18px;
  background: linear-gradient(145deg, white, var(--sakura-50));
}

.focus-danmaku.is-deleted {
  border-color: var(--line);
  background: var(--surface-muted);
}

.focus-topline {
  flex-wrap: wrap;
  gap: 7px;
}

.timecode,
.color-chip {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  border-radius: 999px;
  padding: 5px 8px;
  color: var(--ink-700);
  background: white;
  font-size: 10px;
  font-weight: 700;
}

.color-chip i {
  width: 9px;
  height: 9px;
  border: 1px solid rgb(0 0 0 / 10%);
  border-radius: 50%;
}

.focus-danmaku blockquote {
  margin: 17px 0;
  color: var(--ink-900);
  font-size: 18px;
  font-weight: 700;
  line-height: 1.65;
  word-break: break-word;
}

.author-row {
  gap: 9px;
}

.mini-avatar {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  display: grid;
  place-items: center;
  border-radius: 11px;
  color: var(--sakura-600);
  background: var(--sakura-100);
  font-size: 11px;
  font-weight: 800;
}

.author-row > span:last-child {
  min-width: 0;
  display: grid;
}

.author-row strong {
  color: var(--ink-900);
  font-size: 12px;
}

.author-row small {
  margin-top: 3px;
  color: var(--ink-500);
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

.nearby-list,
.alias-list,
.report-list {
  display: grid;
  gap: 8px;
  padding-bottom: 12px;
}

.nearby-item,
.related-report {
  min-width: 0;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 10px;
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 10px;
  text-align: left;
  color: inherit;
  background: white;
}

.nearby-item:hover,
.related-report:hover {
  border-color: var(--sakura-200);
  background: var(--sakura-50);
}

.nearby-item time {
  min-width: 46px;
  color: var(--sakura-600);
  font-size: 11px;
  font-weight: 800;
}

.nearby-item > span:nth-child(2),
.related-report > span:nth-child(2) {
  min-width: 0;
  display: grid;
}

.nearby-item strong,
.nearby-item small,
.related-report strong,
.related-report small {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.nearby-item strong,
.related-report strong {
  color: var(--ink-900);
  font-size: 12px;
}

.nearby-item small,
.related-report small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 9px;
}

.alias-list article {
  min-width: 0;
  gap: 10px;
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 10px;
  background: var(--surface-muted);
}

.alias-icon,
.report-icon {
  width: 34px;
  height: 34px;
  flex: 0 0 34px;
  border-radius: 10px;
}

.alias-list article > span:last-child {
  min-width: 0;
  display: grid;
}

.alias-list strong {
  color: var(--ink-900);
  font-size: 11px;
}

.alias-list small {
  margin-top: 3px;
  overflow: hidden;
  color: var(--ink-500);
  font-size: 9px;
  text-overflow: ellipsis;
  white-space: nowrap;
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
  .episode-card {
    align-items: flex-start;
    flex-wrap: wrap;
  }

  .episode-stats {
    width: 100%;
    margin-left: 52px;
  }

  .focus-danmaku {
    padding: 14px;
  }

  .nearby-item,
  .related-report {
    grid-template-columns: auto minmax(0, 1fr);
  }

  .nearby-item .el-tag,
  .related-report .el-tag {
    grid-column: 2;
    justify-self: start;
  }
}
</style>
