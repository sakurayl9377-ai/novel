<script setup lang="ts">
import { Monitor, User } from '@element-plus/icons-vue';

import type { VersionInstall } from '@/types/versions';
import { formatDateTime } from '@/utils/format';
import { versionPlatformLabel, versionPlatformTone } from '@/utils/system-operations';

defineProps<{
  modelValue: boolean;
  item: VersionInstall | null;
}>();

const emit = defineEmits<{
  'update:modelValue': [value: boolean];
}>();
</script>

<template>
  <ElDrawer
    :model-value="modelValue"
    class="version-detail-drawer"
    size="min(680px, 96vw)"
    destroy-on-close
    @update:model-value="emit('update:modelValue', $event)"
  >
    <template #header>
      <div v-if="item" class="drawer-heading">
        <span class="eyebrow">INSTALL REPORT #{{ item.id }}</span>
        <h2>{{ item.user.nickname || `用户 #${item.user.id}` }}</h2>
        <div class="heading-tags">
          <ElTag :type="versionPlatformTone(item.platform)" effect="plain">{{ versionPlatformLabel(item.platform) }}</ElTag>
          <ElTag type="info" effect="plain">{{ item.versionName || '未命名版本' }} #{{ item.versionCode }}</ElTag>
        </div>
      </div>
      <span v-else>设备详情</span>
    </template>

    <div v-if="item" class="drawer-body">
      <section class="fact-grid">
        <article><span>账号</span><strong>{{ item.user.nickname || `用户 #${item.user.id}` }}</strong><small>UID {{ item.user.id }}</small></article>
        <article><span>账号状态</span><strong>{{ item.user.status === 'active' ? '正常' : item.user.status }}</strong><small>{{ item.user.email }}</small></article>
        <article><span>设备型号</span><strong>{{ item.deviceModel || '未记录' }}</strong><small>{{ item.platform }}</small></article>
        <article><span>最近上报</span><strong>{{ formatDateTime(item.lastSeenAt) }}</strong><small>首见 {{ formatDateTime(item.firstSeenAt) }}</small></article>
      </section>
      <section class="context-panel">
        <header><ElIcon><Monitor /></ElIcon><span>客户端环境</span></header>
        <dl>
          <div><dt>版本名称</dt><dd>{{ item.versionName || '未记录' }}</dd></div>
          <div><dt>版本号</dt><dd>#{{ item.versionCode }}</dd></div>
          <div><dt>平台</dt><dd>{{ versionPlatformLabel(item.platform) }}</dd></div>
          <div><dt>操作系统</dt><dd>{{ item.osVersion || '未记录' }}</dd></div>
          <div class="wide"><dt>安装标识</dt><dd class="mono wrap">{{ item.installId }}</dd></div>
          <div class="wide"><dt>最近来源 IP</dt><dd>{{ item.lastIp || '未记录' }}</dd></div>
        </dl>
      </section>
      <ElAlert type="info" :closable="false" show-icon>
        <template #title><span><ElIcon><User /></ElIcon>设备上报是客户端自愿上报的运行信息</span></template>
        <template #default>它用于判断版本覆盖和排查兼容性，不代表账号当前在线。</template>
      </ElAlert>
    </div>
    <ElEmpty v-else :image-size="56" description="暂时没有设备详情" />
  </ElDrawer>
</template>

<style scoped>
.drawer-heading { display: grid; min-width: 0; gap: 6px; }
.eyebrow { color: var(--sakura-600); font-size: 9px; font-weight: 800; letter-spacing: .1em; }
.drawer-heading h2 { margin: 0; color: var(--ink-900); font-size: 20px; }
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
.mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
.wrap { overflow-wrap: anywhere; line-height: 1.55; }
.drawer-body :deep(.el-alert__title span) { display: inline-flex; align-items: center; gap: 5px; }
@media (max-width: 560px) {
  .fact-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .fact-grid article:nth-child(2) { border-right: 0; }
  .fact-grid article:nth-child(-n + 2) { border-bottom: 1px solid var(--line); }
}
</style>
