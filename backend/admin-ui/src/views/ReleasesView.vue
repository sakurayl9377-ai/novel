<script setup lang="ts">
import {
  CircleCheck,
  Clock,
  Document,
  Files,
  Link,
  Lock,
  Refresh,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed, onMounted, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import { getReleaseWorkbench } from '@/services/releases';
import type {
  ReleaseBackup,
  ReleaseHistoryItem,
  ReleaseWorkbenchResponse,
} from '@/types/releases';
import { formatBytes, formatDateTime } from '@/utils/format';
import {
  releaseCheckLabel,
  releaseIntegrityLabel,
  releaseIntegrityTone,
} from '@/utils/system-operations';

const loading = ref(false);
const initialized = ref(false);
const workbench = ref<ReleaseWorkbenchResponse>(emptyWorkbench());

const manifestCheck = computed(() => {
  const value = workbench.value.checks.manifest;
  if (typeof value === 'string') return { status: value, reason: value };
  return value;
});

const integrityState = computed(() => {
  const value = workbench.value.integrityStatus;
  if (value === 'unconfigured') {
    return { type: 'info' as const, title: '发布目录尚未配置', detail: '当前环境没有可检查的版本清单和 APK，发布工作台保持只读。' };
  }
  if (value === 'blocked') {
    return { type: 'error' as const, title: '当前发布不可安全使用', detail: '版本清单、APK 或 SHA-256 校验存在阻断项，请先在服务器发布脚本中修复。' };
  }
  if (value === 'warning') {
    return { type: 'warning' as const, title: '发布信息需要人工核对', detail: '文件存在，但完整性校验还没有形成可验证的闭环。' };
  }
  return { type: 'success' as const, title: '当前发布完整性通过', detail: '版本清单、APK 文件和 SHA-256 已完成一致性校验。' };
});

onMounted(() => void loadReleases());

async function loadReleases(): Promise<void> {
  loading.value = true;
  try {
    workbench.value = await getReleaseWorkbench();
  } catch (error) {
    ElMessage.error(errorMessage(error, '发布信息加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function checkTone(value: string): 'success' | 'warning' | 'danger' | 'info' {
  if (['ready', 'verified'].includes(value)) return 'success';
  if (['missing', 'mismatch', 'invalid'].includes(value)) return 'danger';
  if (value === 'unverified') return 'warning';
  return 'info';
}

function releaseMetricTone(value: ReleaseWorkbenchResponse['integrityStatus']): 'default' | 'success' | 'warning' | 'danger' {
  if (value === 'ready') return 'success';
  if (value === 'blocked') return 'danger';
  if (value === 'warning') return 'warning';
  return 'default';
}

function checkReason(value: string): string {
  if (!value) return '清单结构完整';
  return ({
    manifest_missing: '没有找到 version.json',
    manifest_shape_invalid: '版本名称或版本号不完整',
    manifest_checksum_invalid: '清单中的 SHA-256 格式不正确',
    missing: '文件不存在',
    ready: '清单结构有效',
    verified: '文件摘要一致',
    mismatch: '文件摘要与清单不一致',
    unverified: '没有完成摘要校验',
  } as Record<string, string>)[value] || value || '未记录原因';
}

function historyLabel(item: ReleaseHistoryItem): string {
  return item.versionName ? `${item.versionName} #${item.versionCode}` : `版本 #${item.versionCode}`;
}

function asHistory(row: unknown): ReleaseHistoryItem {
  return row as ReleaseHistoryItem;
}

function asBackup(row: unknown): ReleaseBackup {
  return row as ReleaseBackup;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyWorkbench(): ReleaseWorkbenchResponse {
  return {
    configured: false,
    generatedAt: '',
    integrityStatus: 'unconfigured',
    checks: { manifest: 'missing', artifact: 'missing', checksum: 'missing' },
    current: null,
    apk: { exists: false, sizeBytes: 0, modifiedAt: '' },
    history: [],
    backups: [],
  };
}
</script>

<template>
  <div class="page-stack system-page releases-page">
    <section class="workbench-hero">
      <div class="hero-copy">
        <span class="eyebrow">RELEASE CONTROL</span>
        <h2>发布管理</h2>
        <p>把线上版本、安装包和历史备份放在同一处核对。页面只读展示发布状态，实际写入和回滚继续由服务器脚本完成并留下审计记录。</p>
      </div>
      <div class="hero-controls"><ElButton :icon="Refresh" :loading="loading" @click="loadReleases">刷新</ElButton></div>
    </section>

    <ElAlert :title="integrityState.title" :type="integrityState.type" :closable="false" show-icon>
      <template #default>{{ integrityState.detail }}</template>
    </ElAlert>

    <ElSkeleton v-if="!initialized && loading" :rows="9" animated />
    <template v-else-if="workbench.configured">
      <section class="metric-grid release-metrics">
        <MetricCard label="当前版本" :value="workbench.current?.versionName || '未发布'" :hint="`版本号 #${workbench.current?.versionCode || 0}`" :icon="Files" />
        <MetricCard label="完整性" :value="releaseIntegrityLabel(workbench.integrityStatus)" hint="清单 / 文件 / 摘要" :icon="workbench.integrityStatus === 'ready' ? CircleCheck : WarningFilled" :tone="releaseMetricTone(workbench.integrityStatus)" />
        <MetricCard label="安装包大小" :value="formatBytes(workbench.apk.sizeBytes)" :hint="formatDateTime(workbench.apk.modifiedAt)" :icon="Document" />
        <MetricCard label="历史版本" :value="workbench.history.length" hint="保留的版本清单" :icon="Clock" />
        <MetricCard label="备份目录" :value="workbench.backups.length" hint="服务器端备份" :icon="Lock" />
        <MetricCard label="强制升级" :value="workbench.current?.force ? '开启' : '关闭'" hint="当前清单策略" :icon="WarningFilled" :tone="workbench.current?.force ? 'warning' : 'default'" />
      </section>

      <section class="system-panel manifest-panel">
        <header class="section-heading">
          <div><span>CURRENT MANIFEST</span><h3>当前版本清单</h3><p>所有字段来自服务器发布目录的 version.json</p></div>
          <ElTag :type="releaseIntegrityTone(workbench.integrityStatus)" effect="plain">{{ releaseIntegrityLabel(workbench.integrityStatus) }}</ElTag>
        </header>
        <div v-if="workbench.current" class="manifest-body">
          <section class="fact-grid">
            <article><span>版本名称</span><strong>{{ workbench.current.versionName || '未命名' }}</strong><small>#{{ workbench.current.versionCode }}</small></article>
            <article><span>升级策略</span><strong>{{ workbench.current.force ? '强制升级' : '可选升级' }}</strong><small>由客户端启动时读取</small></article>
            <article><span>安装包</span><strong>{{ workbench.apk.exists ? formatBytes(workbench.apk.sizeBytes) : '文件缺失' }}</strong><small>{{ formatDateTime(workbench.apk.modifiedAt) }}</small></article>
            <article><span>清单地址</span><a v-if="workbench.current.apkUrl" :href="workbench.current.apkUrl" target="_blank" rel="noreferrer"><ElIcon><Link /></ElIcon>打开地址</a><strong v-else>未配置</strong><small>客户端下载入口</small></article>
          </section>

          <section class="checks-panel">
            <header><ElIcon><CircleCheck /></ElIcon><span>完整性检查</span></header>
            <div class="check-list">
              <div><span>版本清单</span><ElTag :type="checkTone(manifestCheck.status)" effect="plain">{{ releaseCheckLabel(manifestCheck.status) }}</ElTag><small>{{ checkReason(manifestCheck.reason) }}</small></div>
              <div><span>APK 文件</span><ElTag :type="checkTone(workbench.checks.artifact)" effect="plain">{{ releaseCheckLabel(workbench.checks.artifact) }}</ElTag><small>{{ workbench.apk.exists ? 'app-release.apk 已找到' : '没有找到 app-release.apk' }}</small></div>
              <div><span>SHA-256</span><ElTag :type="checkTone(workbench.checks.checksum)" effect="plain">{{ releaseCheckLabel(workbench.checks.checksum) }}</ElTag><small>{{ workbench.checks.checksum === 'verified' ? '期望值与实际摘要一致' : '请在服务器侧完成校验后再发布' }}</small></div>
            </div>
          </section>

          <section class="checksum-panel">
            <div><span>清单中的摘要</span><code>{{ workbench.current.sha256 || '未填写' }}</code></div>
            <div><span>文件实际摘要</span><code>{{ workbench.current.actualSha256 || '未计算' }}</code></div>
          </section>

          <section v-if="workbench.current.notes.length" class="notes-panel">
            <header><ElIcon><Document /></ElIcon><span>发布说明</span></header>
            <ul><li v-for="note in workbench.current.notes" :key="note">{{ note }}</li></ul>
          </section>
        </div>
        <ElEmpty v-else :image-size="56" description="当前没有有效版本清单" />
      </section>

      <section class="system-grid history-grid">
        <article class="system-panel table-panel">
          <header class="panel-heading"><div><span>VERSION HISTORY</span><h3>历史版本</h3><p>保留清单用于追溯，不代表仍可下载</p></div><ElIcon><Clock /></ElIcon></header>
          <div v-if="workbench.history.length" class="small-table-wrap"><ElTable :data="workbench.history" row-key="fileName" empty-text="暂无历史清单"><ElTableColumn label="版本" min-width="160"><template #default="{ row }"><div class="compact-cell"><strong>{{ historyLabel(asHistory(row)) }}</strong><small>{{ asHistory(row).fileName }}</small></div></template></ElTableColumn><ElTableColumn label="策略" width="90"><template #default="{ row }"><ElTag :type="asHistory(row).force ? 'warning' : 'info'" effect="plain">{{ asHistory(row).force ? '强制' : '可选' }}</ElTag></template></ElTableColumn><ElTableColumn label="摘要" min-width="170"><template #default="{ row }"><code class="short-code">{{ asHistory(row).sha256 || '未记录' }}</code></template></ElTableColumn><ElTableColumn label="更新时间" width="145"><template #default="{ row }">{{ formatDateTime(asHistory(row).modifiedAt) }}</template></ElTableColumn></ElTable></div>
          <ElEmpty v-else :image-size="48" description="暂无历史清单" />
        </article>

        <article class="system-panel table-panel">
          <header class="panel-heading"><div><span>SERVER BACKUPS</span><h3>服务器备份</h3><p>用于人工核对和脚本回滚</p></div><ElIcon><Lock /></ElIcon></header>
          <div v-if="workbench.backups.length" class="small-table-wrap"><ElTable :data="workbench.backups" row-key="name" empty-text="暂无备份目录"><ElTableColumn label="备份目录" min-width="230"><template #default="{ row }"><div class="backup-cell"><span class="backup-icon"><ElIcon><Files /></ElIcon></span><code>{{ asBackup(row).name }}</code></div></template></ElTableColumn><ElTableColumn label="修改时间" width="150"><template #default="{ row }">{{ formatDateTime(asBackup(row).modifiedAt) }}</template></ElTableColumn></ElTable></div>
          <ElEmpty v-else :image-size="48" description="暂无备份目录" />
        </article>
      </section>
    </template>
    <ElEmpty v-else-if="initialized" class="release-empty" :image-size="90" description="当前环境没有配置发布目录" />

    <ElAlert v-if="initialized && workbench.configured" class="release-boundary" type="info" :closable="false" show-icon>
      <template #title><span><ElIcon><Lock /></ElIcon>发布操作保持在服务器脚本边界内</span></template>
      <template #default>后台页面不直接上传、覆盖或回滚安装包；这样可以避免绕过校验和审计链路。</template>
    </ElAlert>
  </div>
</template>

<style scoped>
.system-page { gap: 17px; }.workbench-hero { min-height: 132px; display: flex; align-items: center; justify-content: space-between; gap: 24px; padding: 22px 24px; border: 1px solid var(--line); border-left: 4px solid #9a83b5; border-radius: 8px; background: white; box-shadow: var(--shadow-sm); }.hero-copy { min-width: 0; }.hero-copy h2 { margin: 6px 0 5px; color: var(--ink-900); font-size: 25px; }.hero-copy p { max-width: 800px; margin: 0; color: var(--ink-500); font-size: 12px; line-height: 1.6; }.hero-controls { display: flex; flex: 0 0 auto; align-items: center; gap: 8px; }
.release-metrics { grid-template-columns: repeat(6, minmax(140px, 1fr)); gap: 10px; }.release-metrics :deep(.metric-card) { min-height: 115px; padding: 14px; }.system-panel { min-width: 0; overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }.manifest-panel { overflow: hidden; }.section-heading, .panel-heading { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 16px 17px; border-bottom: 1px solid var(--line); }.section-heading > div:first-child, .panel-heading > div { min-width: 0; display: grid; gap: 3px; }.section-heading span, .panel-heading span { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }.section-heading h3, .panel-heading h3 { margin: 0; color: var(--ink-900); font-size: 16px; }.section-heading p, .panel-heading p { margin: 0; color: var(--ink-500); font-size: 10px; }.panel-heading > .el-icon { color: #9a83b5; font-size: 18px; }
.manifest-body { display: grid; gap: 14px; padding: 16px; }.fact-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); overflow: hidden; border: 1px solid var(--line); border-radius: 7px; }.fact-grid article { display: grid; min-width: 0; gap: 5px; padding: 13px; border-right: 1px solid var(--line); background: var(--surface-muted); }.fact-grid article:last-child { border-right: 0; }.fact-grid span, .fact-grid small { color: var(--ink-500); font-size: 9px; }.fact-grid strong, .fact-grid a { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }.fact-grid a { display: inline-flex; align-items: center; gap: 4px; color: var(--sakura-600); text-decoration: none; }.fact-grid a:hover { text-decoration: underline; }
.checks-panel, .checksum-panel, .notes-panel { padding: 14px; border: 1px solid var(--line); border-radius: 7px; background: white; }.checks-panel > header, .notes-panel > header { display: flex; align-items: center; gap: 7px; color: var(--ink-800); font-size: 12px; font-weight: 700; }.checks-panel > header .el-icon, .notes-panel > header .el-icon { color: var(--sakura-600); }.check-list { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 9px; margin-top: 11px; }.check-list > div { display: grid; align-content: start; gap: 6px; min-width: 0; padding: 11px; background: var(--surface-muted); }.check-list > div > span { color: var(--ink-700); font-size: 10px; font-weight: 700; }.check-list small { color: var(--ink-500); font-size: 9px; line-height: 1.45; }.checksum-panel { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }.checksum-panel > div { min-width: 0; display: grid; gap: 6px; }.checksum-panel span { color: var(--ink-500); font-size: 9px; }.checksum-panel code, .short-code, .backup-cell code { overflow-wrap: anywhere; color: var(--ink-800); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; line-height: 1.5; }.notes-panel ul { display: grid; gap: 5px; margin: 10px 0 0; padding-left: 18px; color: var(--ink-600); font-size: 10px; line-height: 1.55; }
.history-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 14px; }.table-panel { min-width: 0; overflow: hidden; }.small-table-wrap { min-width: 0; overflow-x: auto; }.small-table-wrap :deep(.el-table) { min-width: 600px; }.compact-cell { min-width: 0; display: grid; gap: 3px; }.compact-cell strong { overflow: hidden; color: var(--ink-900); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.compact-cell small { color: var(--ink-500); font-size: 9px; }.short-code { display: block; max-width: 190px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }.backup-cell { display: flex; align-items: center; gap: 8px; min-width: 0; }.backup-icon { width: 28px; height: 28px; display: grid; flex: 0 0 28px; place-items: center; border-radius: 6px; color: #8066a2; background: #f2eef8; }.release-boundary :deep(.el-alert__title span) { display: inline-flex; align-items: center; gap: 5px; }.release-empty { min-height: 220px; border: 1px solid var(--line); border-radius: 8px; background: white; }
@media (max-width: 1320px) { .release-metrics { grid-template-columns: repeat(3, minmax(140px, 1fr)); } }
@media (max-width: 900px) { .workbench-hero { align-items: flex-start; flex-direction: column; }.history-grid { grid-template-columns: 1fr; }.fact-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }.fact-grid article:nth-child(2) { border-right: 0; }.fact-grid article:nth-child(-n + 2) { border-bottom: 1px solid var(--line); }.check-list { grid-template-columns: 1fr; } }
@media (max-width: 620px) { .release-metrics { grid-template-columns: 1fr 1fr; }.checksum-panel { grid-template-columns: 1fr; } }
</style>
