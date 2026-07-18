<script setup lang="ts">
import {
  Clock,
  Refresh,
  Search,
  User,
  VideoCamera,
  View,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import DanmakuContextDrawer from '@/components/danmaku/DanmakuContextDrawer.vue';
import ReportDetailDrawer from '@/components/moderation/ReportDetailDrawer.vue';
import {
  listDanmaku,
  listDanmakuAnime,
  listDanmakuEpisodes,
  updateDanmakuStatus,
} from '@/services/danmaku';
import {
  resolveReportAndDeleteTarget,
  updateReportStatus,
} from '@/services/moderation';
import type {
  DanmakuAnimeCandidate,
  DanmakuEpisodeCandidate,
  DanmakuItem,
  DanmakuStats,
  DanmakuStatus,
} from '@/types/danmaku';
import type { ReportItem, ReportStatus } from '@/types/moderation';
import {
  danmakuModeLabel,
  danmakuStatusLabel,
  formatTimecode,
} from '@/utils/danmaku';
import { formatDateTime } from '@/utils/format';

const loading = ref(false);
const rowUpdatingId = ref<number | null>(null);
const items = ref<DanmakuItem[]>([]);
const total = ref(0);
const statusCounts = ref<Record<string, number>>({});
const stats = ref<DanmakuStats>({ animeCount: 0, videoCount: 0, userCount: 0, importedCount: 0 });
const animeOptions = ref<DanmakuAnimeCandidate[]>([]);
const episodeOptions = ref<DanmakuEpisodeCandidate[]>([]);
const animeLoading = ref(false);
const episodeLoading = ref(false);

const contextOpen = ref(false);
const selectedDanmakuId = ref<number | null>(null);
const reportOpen = ref(false);
const selectedReport = ref<ReportItem | null>(null);
const reportProcessing = ref(false);

const query = reactive({
  q: '',
  status: 'visible' as '' | DanmakuStatus,
  animeId: '',
  episodeId: '',
  page: 1,
  pageSize: 20,
});

const allCount = computed(() => Object.values(statusCounts.value)
  .reduce((sum, value) => sum + Number(value || 0), 0));

onMounted(async () => {
  await Promise.all([loadList(), loadAnimeOptions()]);
});

async function loadList(): Promise<void> {
  loading.value = true;
  try {
    const data = await listDanmaku(query);
    items.value = data.items;
    total.value = data.total;
    statusCounts.value = data.statusCounts;
    stats.value = data.stats;
  } catch (error) {
    ElMessage.error(errorMessage(error, '弹幕列表加载失败'));
  } finally {
    loading.value = false;
  }
}

async function loadAnimeOptions(keyword = ''): Promise<void> {
  animeLoading.value = true;
  try {
    const data = await listDanmakuAnime({ q: keyword, status: query.status || 'visible', limit: 50 });
    animeOptions.value = data.items;
  } catch (error) {
    ElMessage.error(errorMessage(error, '作品选项加载失败'));
  } finally {
    animeLoading.value = false;
  }
}

async function changeAnime(): Promise<void> {
  query.episodeId = '';
  episodeOptions.value = [];
  if (query.animeId) await loadEpisodeOptions();
  search();
}

async function loadEpisodeOptions(): Promise<void> {
  if (!query.animeId) return;
  episodeLoading.value = true;
  try {
    const data = await listDanmakuEpisodes(query.animeId, { status: query.status || 'visible' });
    episodeOptions.value = data.items;
  } catch (error) {
    ElMessage.error(errorMessage(error, '剧集选项加载失败'));
  } finally {
    episodeLoading.value = false;
  }
}

function search(): void {
  query.page = 1;
  void loadList();
}

async function changeStatusFilter(): Promise<void> {
  query.page = 1;
  query.animeId = '';
  query.episodeId = '';
  episodeOptions.value = [];
  await Promise.all([loadAnimeOptions(), loadList()]);
}

function changePage(page: number): void {
  query.page = page;
  void loadList();
}

function changePageSize(pageSize: number): void {
  query.pageSize = pageSize;
  query.page = 1;
  void loadList();
}

function filterStatus(status: '' | DanmakuStatus): void {
  query.status = status;
  query.page = 1;
  void changeStatusFilter();
}

function openContext(itemOrId: DanmakuItem | number): void {
  selectedDanmakuId.value = typeof itemOrId === 'number' ? itemOrId : itemOrId.id;
  reportOpen.value = false;
  contextOpen.value = true;
}

async function changeDanmakuStatus(item: DanmakuItem, status: DanmakuStatus): Promise<void> {
  if (rowUpdatingId.value) return;
  rowUpdatingId.value = item.id;
  try {
    await updateDanmakuStatus(item.id, status);
    ElMessage.success(status === 'deleted' ? '弹幕已删除' : '弹幕已恢复展示');
    if (items.value.length === 1 && query.page > 1) query.page -= 1;
    await loadList();
  } catch (error) {
    ElMessage.error(errorMessage(error, '弹幕状态更新失败'));
  } finally {
    rowUpdatingId.value = null;
  }
}

async function handleContextStatusChanged(): Promise<void> {
  await loadList();
}

function openReport(item: ReportItem): void {
  selectedReport.value = item;
  contextOpen.value = false;
  reportOpen.value = true;
}

async function changeReportStatus(status: ReportStatus): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    await updateReportStatus(selectedReport.value.id, status);
    ElMessage.success(status === 'open' ? '举报已重新打开' : status === 'resolved' ? '举报已处理' : '举报已忽略');
    reportOpen.value = false;
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报状态更新失败'));
  } finally {
    reportProcessing.value = false;
  }
}

async function deleteReportedTarget(): Promise<void> {
  if (!selectedReport.value || reportProcessing.value) return;
  reportProcessing.value = true;
  try {
    await resolveReportAndDeleteTarget(selectedReport.value.id);
    ElMessage.success('举报弹幕已删除，举报已完成');
    reportOpen.value = false;
    await loadList();
  } catch (error) {
    ElMessage.error(errorMessage(error, '举报弹幕处置失败'));
  } finally {
    reportProcessing.value = false;
  }
}

function animeTitle(item: DanmakuItem): string {
  return animeOptions.value.find((option) => option.animeId === item.animeId)?.animeTitle
    || item.animeId
    || '未知作品';
}

function episodeTitle(item: DanmakuItem): string {
  if (query.animeId === item.animeId) {
    return episodeOptions.value.find((option) => option.episodeId === item.episodeId)?.episodeTitle
      || item.episodeId
      || item.videoId;
  }
  return item.episodeId || item.videoId;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}
</script>

<template>
  <div class="page-stack danmaku-page">
    <section class="danmaku-hero">
      <div class="hero-copy">
        <span class="eyebrow">DANMAKU OPERATIONS</span>
        <h2>把弹幕放回播放时间轴里审核</h2>
        <p>查看前后 15 秒同屏内容、发布用户与播放源，集中处理本站用户发布和历史入库的弹幕。</p>
      </div>
      <div class="hero-stats">
        <span><ElIcon><VideoCamera /></ElIcon><b>{{ stats.videoCount }}</b><small>活跃剧集</small></span>
        <span><ElIcon><User /></ElIcon><b>{{ stats.userCount }}</b><small>本站发布者</small></span>
      </div>
    </section>

    <ElAlert
      class="direct-source-notice"
      title="B站弹幕由播放接口实时拉取并在响应中合并，不写入本站数据库；本页不提供重复同步。"
      description="这里仅管理本站用户发布的弹幕和过去已入库的历史记录。"
      type="info"
      :closable="false"
      show-icon
    />

      <section class="summary-strip" aria-label="弹幕状态概览">
        <button type="button" :class="{ active: query.status === '' }" @click="filterStatus('')">
          <span>全部弹幕</span><strong>{{ allCount }}</strong><small>包含历史删除记录</small>
        </button>
        <button type="button" :class="{ active: query.status === 'visible' }" @click="filterStatus('visible')">
          <span>正常展示</span><strong>{{ statusCounts.visible || 0 }}</strong><small>客户端当前可见</small>
        </button>
        <button type="button" :class="{ active: query.status === 'deleted' }" @click="filterStatus('deleted')">
          <span>已删除</span><strong>{{ statusCounts.deleted || 0 }}</strong><small>可核查与恢复</small>
        </button>
        <div class="summary-stats">
          <span><ElIcon><VideoCamera /></ElIcon><b>{{ stats.animeCount }}</b><small>作品</small></span>
          <span><ElIcon><Clock /></ElIcon><b>{{ stats.videoCount }}</b><small>剧集</small></span>
          <span><ElIcon><User /></ElIcon><b>{{ stats.userCount }}</b><small>发布者</small></span>
        </div>
      </section>

      <section class="workbench-card">
        <header class="workbench-toolbar">
          <div class="toolbar-copy">
            <h3>弹幕内容池</h3>
            <p>当前筛选共 {{ total }} 条；点击“查看上下文”读取同屏弹幕、播放源与关联举报。</p>
          </div>
          <div class="filter-row">
            <ElInput
              v-model="query.q"
              clearable
              class="search-input"
              placeholder="搜索弹幕、用户或视频标识"
              :prefix-icon="Search"
              @keyup.enter="search"
              @clear="search"
            />
            <ElSelect v-model="query.status" class="status-select" placeholder="展示状态" @change="changeStatusFilter">
              <ElOption label="全部状态" value="" />
              <ElOption label="正常展示" value="visible" />
              <ElOption label="已删除" value="deleted" />
            </ElSelect>
            <ElSelect
              v-model="query.animeId"
              class="target-select"
              clearable
              filterable
              :loading="animeLoading"
              placeholder="选择作品"
              @change="changeAnime"
            >
              <ElOption label="全部作品" value="" />
              <ElOption v-for="item in animeOptions" :key="item.animeId" :value="item.animeId" :label="item.animeTitle" />
            </ElSelect>
            <ElSelect
              v-model="query.episodeId"
              class="target-select"
              clearable
              filterable
              :loading="episodeLoading"
              :disabled="!query.animeId"
              placeholder="选择剧集"
              @change="search"
            >
              <ElOption label="全部剧集" value="" />
              <ElOption v-for="item in episodeOptions" :key="item.videoId" :value="item.episodeId" :label="item.episodeTitle" />
            </ElSelect>
            <ElButton type="primary" :icon="Search" @click="search">查询</ElButton>
            <ElButton :icon="Refresh" :loading="loading" @click="loadList">刷新</ElButton>
          </div>
        </header>

        <div v-loading="loading" class="danmaku-list">
          <div class="list-head danmaku-grid" aria-hidden="true">
            <span>时间 / 弹幕</span><span>发布者 / 来源</span><span>作品 / 剧集</span><span>样式</span><span>状态 / 时间</span><span>操作</span>
          </div>
          <article v-for="item in items" :key="item.id" class="list-row danmaku-grid">
            <div class="content-cell">
              <span class="timecode">{{ formatTimecode(item.timeMs) }}</span>
              <strong>{{ item.content }}</strong>
              <small>弹幕 #{{ item.id }}</small>
            </div>
            <div class="author-cell">
              <span class="mini-avatar">{{ item.user.nickname?.slice(0, 1) || item.user.id }}</span>
              <span>
                <strong>{{ item.user.nickname || `用户 #${item.user.id}` }}</strong>
                <small>{{ item.isImported ? '历史导入记录' : `本站用户 · UID ${item.user.id}` }}</small>
              </span>
              <ElTag v-if="item.isImported" size="small" effect="plain">历史导入</ElTag>
            </div>
            <div class="target-cell">
              <strong>{{ animeTitle(item) }}</strong>
              <small>{{ episodeTitle(item) }}</small>
              <em>{{ item.videoId }}</em>
            </div>
            <div class="style-cell">
              <span><i :style="{ backgroundColor: item.color }" />{{ item.color }}</span>
              <small>{{ danmakuModeLabel(item.mode) }}</small>
            </div>
            <div class="status-cell">
              <ElTag size="small" :type="item.status === 'visible' ? 'success' : 'info'">{{ danmakuStatusLabel(item.status) }}</ElTag>
              <small>{{ formatDateTime(item.createdAt) }}</small>
            </div>
            <div class="row-actions">
              <ElButton size="small" type="primary" plain :icon="View" @click="openContext(item)">查看上下文</ElButton>
              <ElPopconfirm
                v-if="item.status === 'visible'"
                width="260"
                title="删除后客户端不再展示，确定继续？"
                confirm-button-text="确认删除"
                cancel-button-text="取消"
                @confirm="changeDanmakuStatus(item, 'deleted')"
              >
                <template #reference>
                  <ElButton size="small" type="danger" text :loading="rowUpdatingId === item.id">删除</ElButton>
                </template>
              </ElPopconfirm>
              <ElButton
                v-else
                size="small"
                type="primary"
                text
                :loading="rowUpdatingId === item.id"
                @click="changeDanmakuStatus(item, 'visible')"
              >恢复</ElButton>
            </div>
          </article>
          <div v-if="!loading && items.length === 0" class="friendly-empty list-empty">
            <ElIcon><VideoCamera /></ElIcon><strong>没有符合条件的弹幕</strong><span>调整作品、剧集或关键词后再试</span>
          </div>
        </div>

        <footer v-if="total > 0" class="pagination-row">
          <ElPagination
            background
            :current-page="query.page"
            :page-size="query.pageSize"
            :page-sizes="[10, 20, 50]"
            :pager-count="5"
            layout="total, sizes, prev, pager, next"
            :total="total"
            @current-change="changePage"
            @size-change="changePageSize"
          />
        </footer>
      </section>

    <DanmakuContextDrawer
      v-model="contextOpen"
      :danmaku-id="selectedDanmakuId"
      @status-changed="handleContextStatusChanged"
      @open-danmaku="openContext"
      @open-report="openReport"
    />
    <ReportDetailDrawer
      v-model="reportOpen"
      :report="selectedReport"
      :processing="reportProcessing"
      @change-status="changeReportStatus"
      @delete-target="deleteReportedTarget"
    />
  </div>
</template>

<style scoped>
.danmaku-page {
  --danmaku-grid: minmax(240px, 1.5fr) minmax(175px, 0.9fr) minmax(190px, 1fr) minmax(100px, 0.5fr) minmax(130px, 0.65fr) 178px;
}

.danmaku-hero {
  min-height: 178px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 28px;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  padding: 30px 34px;
  background:
    radial-gradient(circle at 88% 10%, rgb(222 216 255 / 62%), transparent 34%),
    radial-gradient(circle at 75% 100%, rgb(255 211 226 / 55%), transparent 30%),
    white;
  box-shadow: var(--shadow-sm);
}

.hero-copy h2,
.hero-copy p {
  margin: 0;
}

.hero-copy h2 {
  margin-top: 8px;
  color: var(--ink-900);
  font-size: clamp(23px, 2.2vw, 32px);
  letter-spacing: -0.03em;
}

.hero-copy p {
  max-width: 790px;
  margin-top: 9px;
  color: var(--ink-500);
  font-size: 13px;
  line-height: 1.7;
}

.hero-stats {
  display: flex;
  gap: 10px;
}

.hero-stats > span {
  min-width: 104px;
  display: grid;
  place-items: center;
  border: 1px solid rgb(255 255 255 / 60%);
  border-radius: 16px;
  padding: 14px;
  color: var(--sakura-600);
  background: rgb(255 255 255 / 76%);
  box-shadow: var(--shadow-sm);
}

.hero-stats b {
  margin-top: 7px;
  color: var(--ink-900);
  font-size: 22px;
}

.hero-stats small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 9px;
}

.direct-source-notice {
  border-radius: 14px;
}

.summary-strip {
  display: grid;
  grid-template-columns: repeat(3, minmax(130px, 0.65fr)) minmax(260px, 1.5fr);
  gap: 12px;
}

.summary-strip > button,
.summary-stats {
  min-width: 0;
  min-height: 112px;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  border: 1px solid var(--line);
  border-radius: 15px;
  padding: 14px 16px;
  text-align: left;
  color: inherit;
  background: white;
  box-shadow: var(--shadow-sm);
}

.summary-strip > button:hover,
.summary-strip > button.active {
  border-color: var(--sakura-200);
}

.summary-strip > button.active {
  background: linear-gradient(145deg, white, var(--sakura-50));
}

.summary-strip > button span {
  color: var(--ink-500);
  font-size: 11px;
}

.summary-strip > button strong {
  margin-top: auto;
  color: var(--ink-900);
  font-size: 25px;
}

.summary-strip > button small {
  margin-top: 5px;
  color: var(--ink-300);
  font-size: 9px;
}

.summary-stats {
  flex-direction: row;
  align-items: stretch;
  gap: 8px;
}

.summary-stats > span {
  min-width: 0;
  flex: 1;
  display: grid;
  place-items: center;
  align-content: center;
  gap: 5px;
  border-radius: 11px;
  color: var(--sakura-500);
  background: var(--surface-muted);
}

.summary-stats b {
  color: var(--ink-900);
  font-size: 17px;
}

.summary-stats small {
  color: var(--ink-500);
  font-size: 8px;
}

.workbench-card {
  min-width: 0;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: var(--radius-md);
  background: white;
  box-shadow: var(--shadow-sm);
}

.workbench-toolbar {
  display: flex;
  align-items: flex-end;
  justify-content: space-between;
  gap: 18px;
  padding: 18px 20px;
  border-bottom: 1px solid var(--line);
}

.toolbar-copy {
  min-width: 220px;
}

.toolbar-copy h3,
.toolbar-copy p {
  margin: 0;
}

.toolbar-copy h3 {
  color: var(--ink-900);
  font-size: 15px;
}

.toolbar-copy p {
  margin-top: 5px;
  color: var(--ink-500);
  font-size: 10px;
  line-height: 1.5;
}

.filter-row {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 8px;
}

.search-input {
  width: min(260px, 24vw);
}

.status-select {
  width: 124px;
}

.target-select {
  width: 150px;
}

.danmaku-list {
  min-height: 260px;
}

.danmaku-grid {
  display: grid;
  grid-template-columns: var(--danmaku-grid);
  gap: 14px;
}

.list-head {
  align-items: center;
  border-bottom: 1px solid var(--line);
  padding: 10px 20px;
  color: var(--ink-500);
  background: var(--surface-muted);
  font-size: 10px;
  font-weight: 700;
}

.list-row {
  min-width: 0;
  align-items: center;
  border-bottom: 1px solid #f1eef2;
  padding: 14px 20px;
}

.list-row:hover {
  background: #fffafb;
}

.content-cell,
.target-cell,
.style-cell,
.status-cell {
  min-width: 0;
  display: grid;
  justify-items: start;
}

.content-cell {
  grid-template-columns: auto minmax(0, 1fr);
  align-items: center;
  gap: 5px 9px;
}

.content-cell .timecode {
  grid-row: 1 / 3;
  border-radius: 9px;
  padding: 7px 8px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 10px;
  font-weight: 800;
}

.content-cell strong,
.content-cell small,
.target-cell strong,
.target-cell small,
.target-cell em {
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.content-cell strong,
.target-cell strong {
  color: var(--ink-900);
  font-size: 11px;
}

.content-cell small,
.target-cell small,
.target-cell em,
.style-cell small,
.status-cell small {
  color: var(--ink-500);
  font-size: 8px;
  font-style: normal;
}

.target-cell small,
.target-cell em,
.status-cell small {
  margin-top: 3px;
}

.author-cell {
  min-width: 0;
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
}

.mini-avatar {
  width: 32px;
  height: 32px;
  display: grid;
  place-items: center;
  border-radius: 10px;
  color: var(--sakura-600);
  background: var(--sakura-50);
  font-size: 10px;
  font-weight: 800;
}

.author-cell > span:nth-child(2) {
  min-width: 0;
  display: grid;
}

.author-cell strong,
.author-cell small {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.author-cell strong {
  color: var(--ink-900);
  font-size: 10px;
}

.author-cell small {
  margin-top: 3px;
  color: var(--ink-500);
  font-size: 8px;
}

.style-cell > span {
  display: flex;
  align-items: center;
  gap: 5px;
  color: var(--ink-700);
  font-size: 9px;
}

.style-cell i {
  width: 10px;
  height: 10px;
  border: 1px solid rgb(0 0 0 / 10%);
  border-radius: 50%;
}

.style-cell small {
  margin-top: 4px;
}

.row-actions {
  display: flex;
  align-items: center;
  justify-content: flex-end;
  gap: 4px;
}

.row-actions .el-button + .el-button {
  margin-left: 0;
}

.pagination-row {
  display: flex;
  justify-content: flex-end;
  padding: 15px 20px;
  border-top: 1px solid var(--line);
}

.list-empty {
  min-height: 260px;
}

@media (max-width: 1500px) {
  .workbench-toolbar {
    align-items: stretch;
    flex-direction: column;
  }

  .filter-row {
    justify-content: flex-start;
  }

  .search-input {
    width: min(320px, 30vw);
  }

  .list-head {
    display: none;
  }

  .list-row.danmaku-grid {
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px 18px;
  }

  .list-row > div:nth-child(n + 4) {
    border-top: 1px dashed var(--line);
    padding-top: 10px;
  }

  .row-actions {
    justify-content: flex-start;
  }
}

@media (max-width: 1040px) {
  .summary-strip {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .filter-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) repeat(3, minmax(120px, 0.45fr)) auto auto;
  }

  .search-input,
  .status-select,
  .target-select {
    width: 100%;
  }

  .list-row.danmaku-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (max-width: 680px) {
  .danmaku-hero {
    min-height: 0;
    align-items: stretch;
    flex-direction: column;
    padding: 23px;
  }

  .hero-stats > span {
    flex: 1;
  }

  .summary-strip {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .summary-strip > button,
  .summary-stats {
    min-height: 102px;
    padding: 12px;
  }

  .summary-stats {
    grid-column: 1 / -1;
  }

  .workbench-toolbar {
    padding: 15px;
  }

  .filter-row {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }

  .search-input {
    grid-column: 1 / -1;
  }

  .filter-row > .el-button {
    width: 100%;
    margin-left: 0;
  }

  .list-row.danmaku-grid {
    grid-template-columns: 1fr;
    padding: 16px;
  }

  .list-row > div:nth-child(n + 2) {
    border-top: 1px dashed var(--line);
    padding-top: 10px;
  }

  .pagination-row {
    justify-content: center;
    overflow-x: auto;
    padding-inline: 10px;
  }

  .pagination-row :deep(.el-pagination__total),
  .pagination-row :deep(.el-pagination__sizes) {
    display: none;
  }
}
</style>
