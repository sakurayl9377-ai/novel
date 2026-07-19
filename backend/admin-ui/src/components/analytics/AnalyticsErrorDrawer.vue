<script setup lang="ts">
import { CircleCheck, CopyDocument, Document, WarningFilled } from '@element-plus/icons-vue';
import { ElMessage } from 'element-plus';
import { computed } from 'vue';

import type { AnalyticsErrorGroup } from '@/types/analytics';
import { formatDateTime } from '@/utils/format';
import { analyticsErrorSeverity } from '@/utils/analytics';

const props = defineProps<{
  modelValue: boolean;
  error: AnalyticsErrorGroup | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
}>();

const metadataText = computed(() => JSON.stringify(props.error?.metadata || {}, null, 2));
const severity = computed(() => props.error ? analyticsErrorSeverity(props.error) : 'error');

async function copyFingerprint(): Promise<void> {
  const fingerprint = props.error?.fingerprint;
  if (!fingerprint) return;
  try {
    await navigator.clipboard.writeText(fingerprint);
    ElMessage.success('指纹已复制');
  } catch {
    ElMessage.warning('当前浏览器不允许复制，请手动选择指纹');
  }
}
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="analytics-error-drawer"
    size="min(760px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="error" class="error-drawer-heading">
        <div class="heading-topline">
          <span class="eyebrow">ERROR GROUP</span>
          <ElTag :type="severity === 'fatal' ? 'danger' : 'warning'" effect="plain">
            <ElIcon><WarningFilled v-if="severity === 'fatal'" /><CircleCheck v-else /></ElIcon>
            {{ severity === 'fatal' ? '致命错误' : '普通错误' }}
          </ElTag>
        </div>
        <h2>{{ error.type || '未命名错误' }}</h2>
        <p>{{ error.fingerprint }}</p>
      </div>
      <span v-else>错误详情</span>
    </template>

    <div v-if="error" class="error-drawer-body">
      <section class="error-message-block">
        <div class="block-heading"><ElIcon><Document /></ElIcon><span>最近一次错误样本</span></div>
        <p>{{ error.message || '没有错误消息' }}</p>
      </section>

      <section class="error-facts-grid">
        <article><span>发生次数</span><strong>{{ error.occurrences.toLocaleString() }}</strong><small>全部样本</small></article>
        <article><span>受影响安装</span><strong>{{ error.affectedInstalls.toLocaleString() }}</strong><small>去重设备</small></article>
        <article><span>致命次数</span><strong :class="{ danger: error.fatalCount > 0 }">{{ error.fatalCount.toLocaleString() }}</strong><small>按会话计算</small></article>
        <article><span>最近版本</span><strong>{{ error.versionName || `#${error.versionCode || 0}` }}</strong><small>{{ error.platform || '未知平台' }}</small></article>
      </section>

      <section class="error-context-block">
        <header><span>运行上下文</span><ElButton text :icon="CopyDocument" @click="copyFingerprint">复制指纹</ElButton></header>
        <dl>
          <div><dt>页面</dt><dd>{{ error.screen || '未记录' }}</dd></div>
          <div><dt>设备</dt><dd>{{ error.deviceModel || '未记录' }}</dd></div>
          <div><dt>系统</dt><dd>{{ error.osVersion || '未记录' }}</dd></div>
          <div><dt>首次出现</dt><dd>{{ formatDateTime(error.firstSeenAt) }}</dd></div>
          <div><dt>最近出现</dt><dd>{{ formatDateTime(error.lastSeenAt) }}</dd></div>
          <div><dt>发生时间</dt><dd>{{ formatDateTime(error.occurredAt) }}</dd></div>
        </dl>
        <code class="fingerprint">{{ error.fingerprint }}</code>
      </section>

      <ElCollapse :model-value="['stack']" class="error-detail-collapse">
        <ElCollapseItem name="stack">
          <template #title><span class="collapse-title">堆栈信息</span></template>
          <pre>{{ error.stack || '没有堆栈信息' }}</pre>
        </ElCollapseItem>
        <ElCollapseItem name="metadata">
          <template #title><span class="collapse-title">原始元数据</span></template>
          <pre>{{ metadataText }}</pre>
        </ElCollapseItem>
      </ElCollapse>
    </div>
    <ElEmpty v-else :image-size="56" description="暂无错误详情" />
  </ElDrawer>
</template>

<style scoped>
.error-drawer-heading { display: grid; min-width: 0; gap: 5px; }
.heading-topline { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.error-drawer-heading h2 { margin: 0; overflow: hidden; color: var(--ink-900); font-size: 20px; text-overflow: ellipsis; white-space: nowrap; }
.error-drawer-heading p { margin: 0; overflow-wrap: anywhere; color: var(--ink-500); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; }
.error-drawer-body { display: grid; gap: 14px; min-height: 240px; }
.error-message-block, .error-context-block { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.block-heading { display: flex; align-items: center; gap: 7px; color: var(--sakura-600); font-size: 12px; font-weight: 700; }
.error-message-block p { margin: 10px 0 0; overflow-wrap: anywhere; color: var(--ink-800); font-size: 13px; line-height: 1.65; white-space: pre-wrap; }
.error-facts-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); border: 1px solid var(--line); border-radius: 8px; background: white; overflow: hidden; }
.error-facts-grid article { min-width: 0; display: grid; gap: 4px; padding: 12px; border-right: 1px solid var(--line); }
.error-facts-grid article:last-child { border-right: 0; }
.error-facts-grid span, .error-facts-grid small { color: var(--ink-500); font-size: 10px; }
.error-facts-grid strong { overflow: hidden; color: var(--ink-900); font-size: 17px; text-overflow: ellipsis; white-space: nowrap; }
.error-facts-grid strong.danger { color: var(--danger-600, #c64d61); }
.error-context-block header { display: flex; align-items: center; justify-content: space-between; gap: 8px; color: var(--ink-800); font-size: 12px; font-weight: 700; }
.error-context-block dl { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin: 12px 0; }
.error-context-block dl div { min-width: 0; padding: 9px; background: var(--surface-muted); }
.error-context-block dt { color: var(--ink-500); font-size: 9px; }
.error-context-block dd { margin: 4px 0 0; overflow-wrap: anywhere; color: var(--ink-800); font-size: 11px; }
.fingerprint { display: block; overflow-wrap: anywhere; padding: 8px; color: #52687a; background: #eef4f8; font-size: 10px; }
.error-detail-collapse { border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.collapse-title { color: var(--ink-800); font-size: 12px; font-weight: 700; }
.error-detail-collapse :deep(.el-collapse-item__content) { padding: 0 14px 14px; }
.error-detail-collapse pre { max-height: 320px; margin: 0; overflow: auto; padding: 12px; color: #42515e; background: #f6f8fa; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 10px; line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; }
@media (max-width: 560px) {
  .error-facts-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .error-facts-grid article:nth-child(2) { border-right: 0; }
  .error-facts-grid article:nth-child(-n + 2) { border-bottom: 1px solid var(--line); }
  .error-context-block dl { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
</style>
