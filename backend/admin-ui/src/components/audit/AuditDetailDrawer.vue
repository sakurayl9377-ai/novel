<script setup lang="ts">
import { DocumentChecked, User, WarningFilled } from '@element-plus/icons-vue';

import type { AuditItem } from '@/types/audit';
import { formatDateTime } from '@/utils/format';
import { auditActorLabel, auditMethodTone, auditStatusLabel, auditStatusTone } from '@/utils/system-operations';

defineProps<{
  modelValue: boolean;
  item: AuditItem | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
}>();
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="audit-detail-drawer"
    size="min(700px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="item" class="drawer-heading">
        <span class="eyebrow">AUDIT EVENT #{{ item.id }}</span>
        <h2>{{ item.path || '管理员操作' }}</h2>
        <div class="heading-tags">
          <ElTag :type="auditMethodTone(item.method)" effect="plain">{{ item.method }}</ElTag>
          <ElTag :type="auditStatusTone(item.statusCode)" effect="plain">{{ item.statusCode }} {{ auditStatusLabel(item.statusCode) }}</ElTag>
        </div>
      </div>
      <span v-else>审计详情</span>
    </template>

    <div v-if="item" class="drawer-body">
      <section class="fact-grid">
        <article><span>执行管理员</span><strong>{{ auditActorLabel(item) }}</strong><small>{{ item.admin?.email || '系统记录' }}</small></article>
        <article><span>发生时间</span><strong>{{ formatDateTime(item.createdAt) }}</strong><small>服务器记录时间</small></article>
        <article><span>来源地址</span><strong>{{ item.ip || '未记录' }}</strong><small>请求来源 IP</small></article>
        <article><span>请求编号</span><strong>{{ item.requestId || '未记录' }}</strong><small>用于日志关联</small></article>
      </section>

      <section class="context-panel">
        <header><ElIcon><DocumentChecked /></ElIcon><span>请求上下文</span></header>
        <dl>
          <div><dt>HTTP 方法</dt><dd>{{ item.method }}</dd></div>
          <div><dt>状态码</dt><dd :class="{ danger: item.statusCode >= 400 }">{{ item.statusCode }}</dd></div>
          <div class="wide"><dt>请求路径</dt><dd class="mono">{{ item.path }}</dd></div>
          <div class="wide"><dt>User-Agent</dt><dd class="wrap">{{ item.userAgent || '未记录' }}</dd></div>
        </dl>
      </section>

      <ElAlert v-if="item.statusCode >= 400" type="warning" :closable="false" show-icon>
        <template #title><span><ElIcon><WarningFilled /></ElIcon>这次管理员请求没有成功</span></template>
        <template #default>审计日志只记录请求元数据，不保存请求体或敏感配置内容。</template>
      </ElAlert>
      <ElAlert v-else type="info" :closable="false" show-icon>
        <template #title><span><ElIcon><User /></ElIcon>已记录管理员操作</span></template>
        <template #default>如需追踪后续影响，请使用请求编号关联服务日志。</template>
      </ElAlert>
    </div>
    <ElEmpty v-else :image-size="56" description="暂时没有审计详情" />
  </ElDrawer>
</template>

<style scoped>
.drawer-heading { display: grid; min-width: 0; gap: 6px; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.drawer-heading h2 { margin: 0; overflow-wrap: anywhere; color: var(--ink-900); font-size: 18px; line-height: 1.35; }
.heading-tags { display: flex; flex-wrap: wrap; gap: 6px; }
.drawer-body { display: grid; gap: 14px; }
.fact-grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }
.fact-grid article { display: grid; min-width: 0; gap: 4px; padding: 12px; border-right: 1px solid var(--line); }
.fact-grid article:last-child { border-right: 0; }
.fact-grid span, .fact-grid small { color: var(--ink-500); font-size: 10px; }
.fact-grid strong { overflow: hidden; color: var(--ink-900); font-size: 13px; text-overflow: ellipsis; white-space: nowrap; }
.context-panel { padding: 14px; border: 1px solid var(--line); border-radius: 8px; background: white; }
.context-panel header { display: flex; align-items: center; gap: 7px; color: var(--ink-800); font-size: 12px; font-weight: 700; }
.context-panel header .el-icon { color: var(--sakura-600); }
.context-panel dl { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin: 12px 0 0; }
.context-panel dl div { min-width: 0; padding: 9px; background: var(--surface-muted); }
.context-panel dl .wide { grid-column: 1 / -1; }
.context-panel dt { color: var(--ink-500); font-size: 9px; }
.context-panel dd { margin: 4px 0 0; color: var(--ink-800); font-size: 11px; }
.context-panel dd.danger { color: var(--danger-600, #c64d61); }
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.wrap { overflow-wrap: anywhere; line-height: 1.55; }
.drawer-body :deep(.el-alert__title span) { display: inline-flex; align-items: center; gap: 5px; }
@media (max-width: 560px) {
  .fact-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .fact-grid article:nth-child(2) { border-right: 0; }
  .fact-grid article:nth-child(-n + 2) { border-bottom: 1px solid var(--line); }
}
</style>
