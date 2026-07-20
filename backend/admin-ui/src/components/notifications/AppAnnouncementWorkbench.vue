<script setup lang="ts">
import {
  Bell,
  CircleCheck,
  Clock,
  Promotion,
  Refresh,
  SwitchButton,
  View,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import {
  disableAppAnnouncement,
  getAppAnnouncements,
  publishAppAnnouncement,
  republishAppAnnouncement,
} from '@/services/notifications';
import type {
  AppAnnouncementRevision,
  AppAnnouncementWorkbenchResponse,
} from '@/types/notifications';
import { formatDateTime } from '@/utils/format';

const loading = ref(false);
const initialized = ref(false);
const data = ref<AppAnnouncementWorkbenchResponse>(emptyWorkbench());
const page = ref(1);
const pageSize = ref(20);
const editorOpen = ref(false);
const editorMode = ref<'publish' | 'republish'>('publish');
const sourceRevision = ref<AppAnnouncementRevision | null>(null);
const publishing = ref(false);
const disableOpen = ref(false);
const disableNote = ref('');
const disabling = ref(false);
const expandedId = ref(0);
const form = reactive({ title: '', content: '', changeNote: '' });

const currentStatus = computed(() => data.value.current.enabled ? '正在展示' : '已停用');
const publishButtonLabel = computed(() => editorMode.value === 'republish'
  ? '确认重新发布'
  : data.value.current.enabled ? '发布新版本' : '发布并启用');

onMounted(() => void loadAnnouncements());

async function loadAnnouncements(): Promise<void> {
  loading.value = true;
  try {
    data.value = await getAppAnnouncements({ page: page.value, pageSize: pageSize.value });
  } catch (error) {
    ElMessage.error(errorMessage(error, '启动公告加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function openPublish(): void {
  editorMode.value = 'publish';
  sourceRevision.value = null;
  Object.assign(form, {
    title: data.value.current.title || '公告',
    content: data.value.current.content || '',
    changeNote: '',
  });
  editorOpen.value = true;
}

function openRepublish(item: AppAnnouncementRevision): void {
  editorMode.value = 'republish';
  sourceRevision.value = item;
  Object.assign(form, {
    title: item.title,
    content: item.content,
    changeNote: '',
  });
  editorOpen.value = true;
}

async function submitPublish(): Promise<void> {
  if (!form.title.trim()) {
    ElMessage.warning('请填写启动公告标题');
    return;
  }
  if (!form.content.trim()) {
    ElMessage.warning('请填写启动公告内容');
    return;
  }
  if (form.changeNote.trim().length < 4) {
    ElMessage.warning('请填写本次发布原因');
    return;
  }
  publishing.value = true;
  try {
    if (editorMode.value === 'republish' && sourceRevision.value) {
      await republishAppAnnouncement(sourceRevision.value.id, {
        expectedVersion: data.value.current.version,
        changeNote: form.changeNote.trim(),
      });
      ElMessage.success('历史公告已作为新版本重新发布，用户下次启动时会再次看到');
    } else {
      await publishAppAnnouncement({
        expectedVersion: data.value.current.version,
        title: form.title.trim(),
        content: form.content.trim(),
        changeNote: form.changeNote.trim(),
      });
      ElMessage.success('启动公告已发布，用户下次启动 App 时会看到');
    }
    editorOpen.value = false;
    page.value = 1;
    await loadAnnouncements();
  } catch (error) {
    ElMessage.error(errorMessage(error, '启动公告发布失败'));
    await loadAnnouncements();
  } finally {
    publishing.value = false;
  }
}

function openDisable(): void {
  disableNote.value = '';
  disableOpen.value = true;
}

async function confirmDisable(): Promise<void> {
  if (disableNote.value.trim().length < 4) {
    ElMessage.warning('请填写停用原因');
    return;
  }
  disabling.value = true;
  try {
    await disableAppAnnouncement({
      expectedVersion: data.value.current.version,
      changeNote: disableNote.value.trim(),
    });
    disableOpen.value = false;
    ElMessage.success('启动公告已停用，之后启动 App 不再弹出');
    page.value = 1;
    await loadAnnouncements();
  } catch (error) {
    ElMessage.error(errorMessage(error, '启动公告停用失败'));
    await loadAnnouncements();
  } finally {
    disabling.value = false;
  }
}

function toggleExpanded(id: number): void {
  expandedId.value = expandedId.value === id ? 0 : id;
}

function changePage(value: number): void {
  page.value = value;
  void loadAnnouncements();
}

function changePageSize(value: number): void {
  pageSize.value = value;
  page.value = 1;
  void loadAnnouncements();
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): AppAnnouncementWorkbenchResponse {
  return {
    generatedAt: '',
    page: 1,
    pageSize: 20,
    total: 0,
    current: {
      enabled: false,
      id: '',
      version: '',
      title: '公告',
      content: '',
      updatedAt: '',
      activeRevisionId: 0,
      latestRevisionId: 0,
    },
    items: [],
    stats: { total: 0, published: 0, disabled: 0 },
  };
}
</script>

<template>
  <div class="announcement-workbench">
    <section v-loading="loading" class="announcement-current">
      <header>
        <div>
          <span class="eyebrow">CURRENT STARTUP ANNOUNCEMENT</span>
          <h3>当前启动弹窗</h3>
          <p>启用后，用户在新版本公告 ID 下首次启动 App 时看到一次。</p>
        </div>
        <div class="current-actions">
          <ElButton :icon="Refresh" circle title="刷新" :loading="loading" @click="loadAnnouncements" />
          <ElButton v-if="data.current.enabled" type="danger" plain :icon="SwitchButton" @click="openDisable">停用</ElButton>
          <ElButton type="primary" :icon="Promotion" @click="openPublish">
            {{ data.current.enabled ? '发布新版本' : '发布启动公告' }}
          </ElButton>
        </div>
      </header>

      <div class="current-layout">
        <div class="announcement-preview" :class="{ empty: !data.current.content }">
          <div class="preview-app-mark"><ElIcon><Bell /></ElIcon><span>APP 启动弹窗</span></div>
          <strong>{{ data.current.content ? data.current.title : '尚未发布启动公告' }}</strong>
          <p>{{ data.current.content || '发布后可在这里检查用户实际看到的标题和正文。' }}</p>
        </div>
        <dl class="current-meta">
          <div><dt>当前状态</dt><dd><ElTag :type="data.current.enabled ? 'success' : 'info'" effect="plain">{{ currentStatus }}</ElTag></dd></div>
          <div><dt>公告版本</dt><dd>{{ data.current.version || '尚未生成' }}</dd></div>
          <div><dt>最近更新</dt><dd>{{ formatDateTime(data.current.updatedAt) }}</dd></div>
          <div><dt>历史记录</dt><dd>{{ data.stats.total }} 条，其中 {{ data.stats.published }} 次发布</dd></div>
        </dl>
      </div>
    </section>

    <section class="announcement-history">
      <header>
        <div><span class="eyebrow">IMMUTABLE HISTORY</span><h3>启动公告历史</h3><p>发布、停用和历史重发都会保留，不会覆盖旧记录。</p></div>
      </header>
      <div v-loading="loading" class="history-table-wrap">
        <ElTable :data="data.items" row-key="id" empty-text="还没有启动公告历史">
          <ElTableColumn label="版本内容" min-width="330">
            <template #default="{ row }">
              <div class="history-content">
                <strong>{{ row.title }}</strong>
                <small>记录 #{{ row.id }} · {{ row.version }}</small>
                <p :class="{ expanded: expandedId === row.id }">{{ row.content }}</p>
                <ElButton v-if="row.content.length > 80" link :icon="View" @click="toggleExpanded(row.id)">
                  {{ expandedId === row.id ? '收起正文' : '展开正文' }}
                </ElButton>
              </div>
            </template>
          </ElTableColumn>
          <ElTableColumn label="动作" width="118">
            <template #default="{ row }">
              <div class="history-action">
                <ElTag :type="row.enabled ? 'success' : 'info'" effect="plain">
                  {{ row.enabled ? (row.sourceRevisionId ? '历史重发' : '发布') : '停用' }}
                </ElTag>
                <small v-if="row.sourceRevisionId">来源 #{{ row.sourceRevisionId }}</small>
              </div>
            </template>
          </ElTableColumn>
          <ElTableColumn label="操作记录" min-width="220">
            <template #default="{ row }">
              <div class="history-operator">
                <strong>{{ row.operator?.nickname || row.operator?.email || '系统迁移' }}</strong>
                <span>{{ row.note || '未填写原因' }}</span>
              </div>
            </template>
          </ElTableColumn>
          <ElTableColumn label="时间" width="150">
            <template #default="{ row }"><span class="history-time"><ElIcon><Clock /></ElIcon>{{ formatDateTime(row.createdAt) }}</span></template>
          </ElTableColumn>
          <ElTableColumn label="操作" width="116" fixed="right">
            <template #default="{ row }"><ElButton type="primary" link :icon="Promotion" @click="openRepublish(row as AppAnnouncementRevision)">重新发布</ElButton></template>
          </ElTableColumn>
        </ElTable>
        <ElEmpty v-if="initialized && !loading && !data.items.length" :image-size="58" description="还没有启动公告历史">
          <ElButton type="primary" :icon="Promotion" @click="openPublish">发布第一条公告</ElButton>
        </ElEmpty>
      </div>
      <footer v-if="data.total" class="history-footer">
        <span>共 {{ data.total }} 条不可变记录</span>
        <ElPagination
          background
          layout="sizes, prev, pager, next"
          :current-page="page"
          :page-size="pageSize"
          :page-sizes="[10, 20, 50]"
          :total="data.total"
          @current-change="changePage"
          @size-change="changePageSize"
        />
      </footer>
    </section>

    <ElDialog
      v-model="editorOpen"
      :title="editorMode === 'republish' ? '重新发布历史启动公告' : '发布 App 启动公告'"
      width="min(640px, 94vw)"
      :close-on-click-modal="false"
    >
      <div class="announcement-form">
        <ElAlert
          type="warning"
          :closable="false"
          show-icon
          title="投递位置：App 启动弹窗"
        >
          <template #default>发布会生成新的公告 ID；用户下次启动 App 时会看到一次，不会进入消息中心。</template>
        </ElAlert>
        <ElForm label-position="top">
          <ElFormItem label="公告标题" required><ElInput v-model="form.title" :disabled="editorMode === 'republish'" maxlength="80" show-word-limit /></ElFormItem>
          <ElFormItem label="公告正文" required><ElInput v-model="form.content" :disabled="editorMode === 'republish'" type="textarea" :rows="7" maxlength="4000" show-word-limit /></ElFormItem>
          <ElFormItem label="发布原因" required><ElInput v-model="form.changeNote" maxlength="500" show-word-limit placeholder="例如：发布暑期活动启动公告" /></ElFormItem>
        </ElForm>
        <div class="publish-check"><ElIcon><CircleCheck /></ElIcon><span>发布成功后会立即成为当前启动公告，并写入一条不可变历史记录。</span></div>
      </div>
      <template #footer><ElButton @click="editorOpen = false">取消</ElButton><ElButton type="primary" :icon="Promotion" :loading="publishing" @click="submitPublish">{{ publishButtonLabel }}</ElButton></template>
    </ElDialog>

    <ElDialog v-model="disableOpen" title="停用启动公告" width="min(520px, 92vw)" :close-on-click-modal="false">
      <ElAlert type="warning" :closable="false" show-icon title="停用后，新启动 App 的用户不再看到这条弹窗" />
      <ElForm label-position="top" class="disable-form"><ElFormItem label="停用原因" required><ElInput v-model="disableNote" maxlength="500" show-word-limit placeholder="例如：活动已经结束" /></ElFormItem></ElForm>
      <template #footer><ElButton @click="disableOpen = false">取消</ElButton><ElButton type="danger" :icon="SwitchButton" :loading="disabling" @click="confirmDisable">确认停用</ElButton></template>
    </ElDialog>
  </div>
</template>

<style scoped>
.announcement-workbench { display: grid; gap: 16px; }
.announcement-current, .announcement-history { overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }
.announcement-current > header, .announcement-history > header { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 17px 18px; border-bottom: 1px solid var(--line); }
.announcement-current h3, .announcement-history h3 { margin: 3px 0 0; color: var(--ink-900); font-size: 16px; }
.announcement-current header p, .announcement-history header p { margin: 3px 0 0; color: var(--ink-500); font-size: 10px; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.current-actions { display: flex; align-items: center; gap: 8px; }
.current-layout { display: grid; grid-template-columns: minmax(300px, 1.1fr) minmax(280px, .9fr); gap: 0; }
.announcement-preview { min-height: 220px; display: flex; align-items: flex-start; flex-direction: column; justify-content: center; padding: 28px 32px; border-right: 1px solid var(--line); background: #fffafb; }
.preview-app-mark { display: inline-flex; align-items: center; gap: 6px; margin-bottom: 18px; color: var(--sakura-700); font-size: 10px; font-weight: 700; }
.preview-app-mark .el-icon { font-size: 18px; }
.announcement-preview > strong { color: var(--ink-900); font-size: 22px; }
.announcement-preview > p { max-width: 620px; margin: 10px 0 0; color: var(--ink-700); font-size: 13px; line-height: 1.75; white-space: pre-wrap; word-break: break-word; }
.announcement-preview.empty { background: var(--surface-muted); }
.announcement-preview.empty > strong, .announcement-preview.empty > p { color: var(--ink-500); }
.current-meta { display: grid; align-content: center; gap: 0; margin: 0; padding: 18px 24px; }
.current-meta > div { display: grid; grid-template-columns: 92px minmax(0, 1fr); align-items: center; gap: 12px; min-height: 44px; border-bottom: 1px solid var(--line); }
.current-meta > div:last-child { border-bottom: 0; }
.current-meta dt { color: var(--ink-500); font-size: 10px; }
.current-meta dd { min-width: 0; margin: 0; overflow-wrap: anywhere; color: var(--ink-800); font-size: 11px; }
.history-table-wrap { overflow-x: auto; }
.history-table-wrap :deep(.el-table) { min-width: 980px; }
.history-content, .history-action, .history-operator { min-width: 0; display: grid; gap: 4px; }
.history-content strong, .history-operator strong { color: var(--ink-900); font-size: 11px; }
.history-content small, .history-action small { color: var(--ink-400); font-size: 9px; }
.history-content p { max-width: 440px; margin: 2px 0 0; overflow: hidden; color: var(--ink-600); font-size: 10px; line-height: 1.55; text-overflow: ellipsis; white-space: nowrap; }
.history-content p.expanded { overflow: visible; white-space: pre-wrap; }
.history-content .el-button { width: fit-content; padding: 0; font-size: 10px; }
.history-operator span { color: var(--ink-500); font-size: 10px; line-height: 1.45; }
.history-time { display: inline-flex; align-items: center; gap: 5px; color: var(--ink-500); font-size: 10px; }
.history-footer { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 13px 16px; border-top: 1px solid var(--line); }
.history-footer > span { color: var(--ink-500); font-size: 10px; }
.announcement-form { display: grid; gap: 16px; }
.announcement-form :deep(.el-form-item:last-child) { margin-bottom: 0; }
.publish-check { display: flex; align-items: flex-start; gap: 7px; color: #3f705e; font-size: 10px; line-height: 1.5; }
.publish-check .el-icon { flex: 0 0 auto; margin-top: 2px; }
.disable-form { margin-top: 18px; }
@media (max-width: 850px) {
  .current-layout { grid-template-columns: 1fr; }
  .announcement-preview { border-right: 0; border-bottom: 1px solid var(--line); }
}
@media (max-width: 620px) {
  .announcement-current > header, .announcement-history > header { align-items: flex-start; flex-direction: column; }
  .current-actions { width: 100%; flex-wrap: wrap; }
  .announcement-preview { min-height: 180px; padding: 22px 18px; }
  .announcement-preview > strong { font-size: 18px; }
  .history-footer { align-items: flex-start; flex-direction: column; }
}
</style>
