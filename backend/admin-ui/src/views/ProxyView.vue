<script setup lang="ts">
import {
  CircleCheck,
  Connection,
  Delete,
  Download,
  Link,
  Monitor,
  Plus,
  Refresh,
  Search,
  Setting,
  Timer,
  WarningFilled,
} from '@element-plus/icons-vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { computed, onMounted, reactive, ref } from 'vue';

import MetricCard from '@/components/MetricCard.vue';
import {
  addProxySubscription,
  deleteProxySubscription,
  enableProxyManualMode,
  getProxyStatus,
  setProxyGroup,
  setProxyNode,
  setProxyService,
  testProxy,
  testProxyNodes,
  updateAllProxySubscriptions,
  updateProxySubscription,
} from '@/services/proxy';
import type {
  ProxyConnectivityTest,
  ProxyGroup,
  ProxyNode,
  ProxyNodeTestResult,
  ProxyStatus,
} from '@/types/proxy';
import { formatDateTime } from '@/utils/format';
import {
  proxyGroupLabel,
  proxyNodeState,
  proxyNodeTone,
  proxyServiceLabel,
  proxyServiceTone,
} from '@/utils/proxy';

const loading = ref(false);
const initialized = ref(false);
const status = ref<ProxyStatus>(emptyStatus());
const busyAction = ref('');
const openedSections = ref<string[]>(['runtime', 'subscriptions', 'strategies', 'nodes']);
const nodeKeyword = ref('');
const nodeFilter = ref<'all' | 'available' | 'unavailable'>('all');
const nodePage = ref(1);
const nodePageSize = 20;
const groupSelections = reactive<Record<string, string>>({});
const subscriptionDialogOpen = ref(false);
const subscriptionForm = reactive({ name: '', url: '' });
const connectivity = ref<ProxyConnectivityTest | null>(null);
const nodeTest = ref<ProxyNodeTestResult | null>(null);

const filteredNodes = computed(() => {
  const keyword = nodeKeyword.value.trim().toLowerCase();
  return status.value.nodes.filter((node) => {
    if (nodeFilter.value === 'available' && !node.alive) return false;
    if (nodeFilter.value === 'unavailable' && node.alive) return false;
    return !keyword || node.name.toLowerCase().includes(keyword) || node.type.toLowerCase().includes(keyword);
  });
});
const pagedNodes = computed(() => {
  const start = (nodePage.value - 1) * nodePageSize;
  return filteredNodes.value.slice(start, start + nodePageSize);
});
const availableNodeCount = computed(() => status.value.nodes.filter((node) => node.alive).length);
const manualGroup = computed(() => status.value.groups.find((group) => group.name === 'NODE-MANUAL'));
const serviceTone = computed(() => proxyServiceTone(status.value.service.active, status.value.service.enabled));
const serviceLabel = computed(() => proxyServiceLabel(status.value.service.active, status.value.service.enabled));

onMounted(() => void loadProxy());

async function loadProxy(): Promise<void> {
  loading.value = true;
  try {
    applyStatus(await getProxyStatus());
  } catch (error) {
    ElMessage.error(errorMessage(error, '代理状态加载失败'));
  } finally {
    loading.value = false;
    initialized.value = true;
  }
}

function applyStatus(next: ProxyStatus): void {
  status.value = next;
  for (const group of next.groups) {
    if (!(group.name in groupSelections)) groupSelections[group.name] = group.current || group.options[0] || '';
  }
  nodePage.value = 1;
}

async function runAction<T extends ProxyStatus>(key: string, action: () => Promise<T>, successMessage = ''): Promise<boolean> {
  busyAction.value = key;
  try {
    applyStatus(await action());
    if (successMessage) ElMessage.success(successMessage);
    return true;
  } catch (error) {
    ElMessage.error(errorMessage(error, '代理操作失败'));
    return false;
  } finally {
    busyAction.value = '';
  }
}

async function changeService(value: boolean | string | number): Promise<void> {
  const enabled = value === true || value === 'true';
  try {
    await ElMessageBox.confirm(
      enabled ? '确认启动代理服务并开启定时更新？' : '确认停止代理服务并关闭定时更新？',
      enabled ? '启动代理服务' : '停止代理服务',
      { type: enabled ? 'info' : 'warning', confirmButtonText: '确认', cancelButtonText: '取消' },
    );
  } catch {
    return;
  }
  await runAction('service', () => setProxyService(enabled), enabled ? '代理服务已启动' : '代理服务已停止');
}

async function enableManual(): Promise<void> {
  await runAction('manual-mode', enableProxyManualMode, '手动节点模式已准备好');
}

async function changeGroup(group: ProxyGroup, choice: string | number | boolean): Promise<void> {
  const selected = String(choice || '');
  if (!selected || selected === group.current) return;
  groupSelections[group.name] = selected;
  const succeeded = await runAction(`group:${group.name}`, () => setProxyGroup(group.name, selected));
  if (!succeeded) groupSelections[group.name] = group.current;
}

async function changeNode(node: ProxyNode): Promise<void> {
  if (!status.value.manualModeEnabled) {
    ElMessage.warning('请先启用手动节点模式');
    return;
  }
  try {
    await ElMessageBox.confirm(`确认将流量切换到「${node.name}」？`, '切换代理节点', {
      type: 'warning',
      confirmButtonText: '切换',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  await runAction('node', () => setProxyNode(node.name), '代理节点已切换');
}

async function openSubscriptionDialog(): Promise<void> {
  subscriptionForm.name = '';
  subscriptionForm.url = '';
  subscriptionDialogOpen.value = true;
}

async function submitSubscription(): Promise<void> {
  if (!subscriptionForm.name.trim() || !subscriptionForm.url.trim()) {
    ElMessage.warning('请填写订阅名称和订阅地址');
    return;
  }
  const succeeded = await runAction(
    'subscription-add',
    () => addProxySubscription({ name: subscriptionForm.name.trim(), url: subscriptionForm.url.trim() }),
    '订阅已添加，节点正在更新',
  );
  if (succeeded) subscriptionDialogOpen.value = false;
}

async function updateSubscription(id: string): Promise<void> {
  try {
    await ElMessageBox.confirm('确认立即更新这条订阅？', '更新订阅', { confirmButtonText: '更新', cancelButtonText: '取消' });
  } catch {
    return;
  }
  await runAction(`subscription-update:${id}`, () => updateProxySubscription(id), '订阅更新完成');
}

async function removeSubscription(id: string, name: string): Promise<void> {
  try {
    await ElMessageBox.confirm(`删除「${name}」后，相关节点会在下一次配置更新中移除。`, '删除订阅', {
      type: 'warning',
      confirmButtonText: '删除',
      cancelButtonText: '取消',
    });
  } catch {
    return;
  }
  await runAction(`subscription-delete:${id}`, () => deleteProxySubscription(id), '订阅已删除');
}

async function updateAll(): Promise<void> {
  try {
    await ElMessageBox.confirm('确认更新全部订阅？这可能需要几分钟。', '批量更新订阅', { confirmButtonText: '更新', cancelButtonText: '取消' });
  } catch {
    return;
  }
  await runAction('subscription-update-all', updateAllProxySubscriptions, '全部订阅更新完成');
}

async function runConnectivityTest(): Promise<void> {
  busyAction.value = 'connectivity';
  try {
    connectivity.value = await testProxy();
  } catch (error) {
    ElMessage.error(errorMessage(error, '代理连通性测试失败'));
  } finally {
    busyAction.value = '';
  }
}

async function runNodeTest(): Promise<void> {
  busyAction.value = 'nodes-test';
  try {
    nodeTest.value = await testProxyNodes();
    applyStatus(await getProxyStatus());
  } catch (error) {
    ElMessage.error(errorMessage(error, '节点测速失败'));
  } finally {
    busyAction.value = '';
  }
}

function onNodeFilterChange(): void {
  nodePage.value = 1;
}

function groupCurrent(group: ProxyGroup): string {
  return groupSelections[group.name] || group.current || group.options[0] || '';
}

function nodeActionDisabled(node: ProxyNode): boolean {
  return !status.value.manualModeEnabled || node.name === manualGroup.value?.current;
}

function asNode(row: unknown): ProxyNode {
  return row as ProxyNode;
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function emptyStatus(): ProxyStatus {
  return {
    service: { active: false, enabled: false },
    subscription: { configured: false, timer: { active: false, nextRun: '' } },
    subscriptions: [],
    config: { path: '', exists: false },
    version: '',
    runtime: { mixedPort: 0, mode: '', logLevel: '', ipv6: false },
    groups: [],
    nodes: [],
    nodeTotal: 0,
    manualModeEnabled: false,
  };
}
</script>

<template>
  <div class="page-stack proxy-page">
    <section class="page-action-row proxy-heading">
      <div>
        <span class="eyebrow">PROXY CONTROL</span>
        <h2>代理管理</h2>
        <p>服务状态、订阅节点与策略切换集中管理，节点切换走单次受控操作。</p>
      </div>
      <div class="action-row">
        <ElButton :icon="Refresh" :loading="loading" @click="loadProxy">刷新状态</ElButton>
        <ElButton type="primary" :icon="Plus" @click="openSubscriptionDialog">添加订阅</ElButton>
      </div>
    </section>

    <ElAlert
      v-if="initialized && !status.service.active"
      title="代理服务当前未运行"
      type="warning"
      :closable="false"
      show-icon
    >
      <template #default>订阅更新、策略组和节点测速需要服务在线。</template>
    </ElAlert>
    <ElAlert
      v-else-if="initialized && !status.manualModeEnabled"
      title="手动节点模式尚未启用"
      type="info"
      :closable="false"
      show-icon
    >
      <template #default>当前仍由自动策略选择节点；需要人工切换时再启用手动模式。</template>
    </ElAlert>

    <section class="metric-grid proxy-metrics">
      <MetricCard label="服务状态" :value="serviceLabel" :hint="status.service.active ? 'mihomo 正在运行' : '等待启动'" :icon="Connection" :tone="serviceTone" />
      <MetricCard label="订阅数量" :value="status.subscriptions.length" :hint="status.subscription.configured ? '已配置订阅源' : '尚未配置订阅'" :icon="Download" />
      <MetricCard label="节点总数" :value="status.nodeTotal" :hint="`${availableNodeCount} 个当前可用`" :icon="Link" />
      <MetricCard label="代理端口" :value="status.runtime.mixedPort || '-'" :hint="status.runtime.mode || '运行模式未知'" :icon="Monitor" />
      <MetricCard label="定时更新" :value="status.subscription.timer.active ? '已开启' : '已关闭'" :hint="status.subscription.timer.nextRun || '暂无下次执行时间'" :icon="Timer" :tone="status.subscription.timer.active ? 'success' : 'default'" />
    </section>

    <ElCollapse v-model="openedSections" class="proxy-collapse">
      <ElCollapseItem name="runtime">
        <template #title><div class="collapse-title"><div><strong>服务与运行时</strong><small>{{ status.config.path || '配置路径未返回' }}</small></div><ElTag :type="serviceTone" effect="plain">{{ serviceLabel }}</ElTag></div></template>
        <div class="runtime-grid">
          <div class="control-line"><div><span>服务开关</span><small>{{ status.service.active ? '当前进程在线' : '当前进程离线' }}</small></div><ElSwitch :model-value="status.service.enabled" :loading="busyAction === 'service'" @change="changeService" /></div>
          <div class="control-line"><div><span>手动节点模式</span><small>{{ status.manualModeEnabled ? '可以从节点列表直接切换' : '需要修改 Mihomo 策略组' }}</small></div><ElButton v-if="!status.manualModeEnabled" size="small" type="primary" :loading="busyAction === 'manual-mode'" @click="enableManual">启用手动模式</ElButton><ElTag v-else type="success" effect="plain"><ElIcon><CircleCheck /></ElIcon> 已启用</ElTag></div>
          <div class="runtime-fact"><span>版本</span><strong>{{ status.version || '未读取' }}</strong></div>
          <div class="runtime-fact"><span>日志级别</span><strong>{{ status.runtime.logLevel || '未读取' }}</strong></div>
          <div class="runtime-fact"><span>IPv6</span><strong>{{ status.runtime.ipv6 ? '开启' : '关闭' }}</strong></div>
          <div class="runtime-fact"><span>定时任务</span><strong>{{ status.subscription.timer.active ? 'active' : 'inactive' }}</strong></div>
        </div>
      </ElCollapseItem>

      <ElCollapseItem name="subscriptions">
        <template #title><div class="collapse-title"><div><strong>订阅源</strong><small>地址只在新增时输入，列表不回显完整 URL</small></div><ElTag type="info" effect="plain">{{ status.subscriptions.length }} 条</ElTag></div></template>
        <div class="sub-toolbar"><span>{{ status.subscription.configured ? '订阅配置正常' : '没有可用订阅源' }}</span><ElButton size="small" :icon="Refresh" :loading="busyAction === 'subscription-update-all'" @click.stop="updateAll">更新全部</ElButton></div>
        <ElTable :data="status.subscriptions" row-key="id" empty-text="暂无订阅源">
          <ElTableColumn label="名称" min-width="190"><template #default="{ row }"><div class="primary-cell"><strong>{{ row.name }}</strong><small>{{ row.id }}</small></div></template></ElTableColumn>
          <ElTableColumn label="节点数" width="100"><template #default="{ row }">{{ row.nodeCount }}</template></ElTableColumn>
          <ElTableColumn label="操作" width="220" align="right"><template #default="{ row }"><ElButton text type="primary" :loading="busyAction === `subscription-update:${row.id}`" @click="updateSubscription(row.id)">更新</ElButton><ElButton text type="danger" :loading="busyAction === `subscription-delete:${row.id}`" @click="removeSubscription(row.id, row.name)">删除</ElButton></template></ElTableColumn>
        </ElTable>
      </ElCollapseItem>

      <ElCollapseItem name="strategies">
        <template #title><div class="collapse-title"><div><strong>策略组</strong><small>使用下拉选择，不需要手动输入组名或节点名</small></div><ElTag type="warning" effect="plain">{{ status.groups.length }} 组</ElTag></div></template>
        <div v-if="status.groups.length" class="strategy-grid">
          <article v-for="group in status.groups" :key="group.name" class="strategy-item">
            <div class="strategy-heading"><div><strong>{{ proxyGroupLabel(group) }}</strong><small>{{ group.name }}</small></div><ElTag effect="plain">{{ group.type }}</ElTag></div>
            <ElSelect :model-value="groupCurrent(group)" filterable :loading="busyAction === `group:${group.name}`" @change="changeGroup(group, $event)">
              <ElOption v-for="option in group.options" :key="option" :label="option" :value="option" />
            </ElSelect>
            <small class="current-note">当前：{{ group.current || '未选择' }}</small>
          </article>
        </div>
        <ElEmpty v-else :image-size="50" description="服务在线后读取策略组" />
      </ElCollapseItem>

      <ElCollapseItem name="nodes">
        <template #title><div class="collapse-title"><div><strong>节点列表</strong><small>测速结果与手动切换入口</small></div><ElTag :type="availableNodeCount ? 'success' : 'danger'" effect="plain">{{ availableNodeCount }}/{{ status.nodeTotal }} 可用</ElTag></div></template>
        <div class="node-toolbar">
          <ElInput v-model="nodeKeyword" clearable :prefix-icon="Search" placeholder="搜索节点名称或类型" @input="onNodeFilterChange" />
          <ElSelect v-model="nodeFilter" @change="onNodeFilterChange"><ElOption label="全部节点" value="all" /><ElOption label="仅可用" value="available" /><ElOption label="仅不可用" value="unavailable" /></ElSelect>
          <ElButton :icon="Refresh" :loading="busyAction === 'nodes-test'" @click="runNodeTest">测试全部节点</ElButton>
        </div>
        <ElTable :data="pagedNodes" row-key="name" empty-text="没有符合条件的节点">
          <ElTableColumn label="节点" min-width="260"><template #default="{ row }"><div class="primary-cell"><strong>{{ row.name }}</strong><small>{{ row.type }}</small></div></template></ElTableColumn>
          <ElTableColumn label="状态" width="130"><template #default="{ row }"><ElTag :type="proxyNodeTone(asNode(row))" effect="plain">{{ proxyNodeState(asNode(row)) }}</ElTag></template></ElTableColumn>
          <ElTableColumn label="操作" width="150" align="right"><template #default="{ row }"><ElButton size="small" type="primary" :disabled="nodeActionDisabled(asNode(row))" :loading="busyAction === 'node'" @click="changeNode(asNode(row))">{{ asNode(row).name === manualGroup?.current ? '当前节点' : '切换' }}</ElButton></template></ElTableColumn>
        </ElTable>
        <div class="table-footer"><span>共 {{ filteredNodes.length }} 个节点</span><ElPagination v-if="filteredNodes.length > nodePageSize" v-model:current-page="nodePage" :page-size="nodePageSize" :total="filteredNodes.length" layout="prev, pager, next" background /></div>
      </ElCollapseItem>

      <ElCollapseItem name="checks">
        <template #title><div class="collapse-title"><div><strong>连通性检查</strong><small>按需执行，不在页面加载时阻塞主工作台</small></div><ElTag :type="connectivity?.ok ? 'success' : connectivity ? 'danger' : 'info'" effect="plain">{{ connectivity ? (connectivity.ok ? '通过' : '有失败项') : '未测试' }}</ElTag></div></template>
        <div class="check-toolbar"><ElButton type="primary" :loading="busyAction === 'connectivity'" @click="runConnectivityTest">测试代理出口</ElButton><span v-if="connectivity">{{ connectivity.checks.filter((item) => item.ok).length }}/{{ connectivity.checks.length }} 项通过</span></div>
        <div v-if="connectivity" class="check-grid"><article v-for="item in connectivity.checks" :key="item.name"><ElIcon :class="item.ok ? 'ok' : 'bad'"><CircleCheck v-if="item.ok" /><WarningFilled v-else /></ElIcon><div><strong>{{ item.name }}</strong><small>{{ item.ok ? `HTTP ${item.status}` : '连接失败' }}{{ item.value ? ` · ${item.value}` : '' }}</small></div></article></div>
        <ElEmpty v-else :image-size="48" description="尚未执行连通性检查" />
      </ElCollapseItem>
    </ElCollapse>

    <ElDialog v-model="subscriptionDialogOpen" title="添加代理订阅" width="520px" destroy-on-close>
      <ElForm label-position="top" @submit.prevent="submitSubscription">
        <ElFormItem label="订阅名称" required><ElInput v-model="subscriptionForm.name" maxlength="80" show-word-limit placeholder="例如：主线路" /></ElFormItem>
        <ElFormItem label="订阅地址" required><ElInput v-model="subscriptionForm.url" type="password" show-password placeholder="仅支持 HTTPS 订阅地址" /></ElFormItem>
      </ElForm>
      <template #footer><ElButton @click="subscriptionDialogOpen = false">取消</ElButton><ElButton type="primary" :loading="busyAction === 'subscription-add'" @click="submitSubscription">添加并更新</ElButton></template>
    </ElDialog>
  </div>
</template>

<style scoped>
.proxy-page { gap: 16px; }.proxy-heading { padding-bottom: 2px; }.proxy-heading h2 { margin: 6px 0 4px; font-size: 25px; }.proxy-heading p { margin: 0; color: var(--ink-500); font-size: 12px; }.action-row { display: flex; align-items: center; gap: 8px; }.proxy-metrics { grid-template-columns: repeat(5, minmax(145px, 1fr)); gap: 10px; }.proxy-metrics :deep(.metric-card) { min-height: 112px; padding: 14px; }.proxy-collapse { overflow: hidden; border: 1px solid var(--line); border-radius: 8px; background: white; }.proxy-collapse :deep(.el-collapse-item__header) { min-height: 66px; padding: 0 18px; }.proxy-collapse :deep(.el-collapse-item__wrap) { border-top: 1px solid var(--line); }.proxy-collapse :deep(.el-collapse-item__content) { padding: 16px 18px 20px; }.collapse-title { min-width: 0; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding-right: 8px; }.collapse-title > div { min-width: 0; display: grid; gap: 4px; }.collapse-title strong { color: var(--ink-900); font-size: 14px; }.collapse-title small { overflow: hidden; color: var(--ink-500); font-size: 11px; text-overflow: ellipsis; white-space: nowrap; }.runtime-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }.control-line, .runtime-fact { min-width: 0; display: flex; align-items: center; justify-content: space-between; gap: 12px; min-height: 70px; padding: 13px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }.control-line > div, .runtime-fact { display: grid; gap: 5px; }.control-line span, .runtime-fact span { color: var(--ink-500); font-size: 11px; }.control-line small { color: var(--ink-500); font-size: 10px; }.runtime-fact strong { overflow: hidden; color: var(--ink-900); font-size: 14px; text-overflow: ellipsis; white-space: nowrap; }.sub-toolbar, .node-toolbar, .check-toolbar, .table-footer { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 12px; color: var(--ink-500); font-size: 11px; }.node-toolbar { justify-content: flex-start; }.node-toolbar :deep(.el-input) { width: min(320px, 100%); }.node-toolbar :deep(.el-select) { width: 140px; }.primary-cell { min-width: 0; display: grid; gap: 4px; }.primary-cell strong { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }.primary-cell small { color: var(--ink-500); font-size: 10px; }.strategy-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }.strategy-item { min-width: 0; display: grid; gap: 9px; padding: 13px; border: 1px solid var(--line); border-radius: 7px; background: var(--surface-muted); }.strategy-heading { display: flex; justify-content: space-between; gap: 8px; }.strategy-heading > div { min-width: 0; display: grid; gap: 3px; }.strategy-heading strong { overflow: hidden; color: var(--ink-900); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }.strategy-heading small, .current-note { overflow: hidden; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }.current-note { display: block; }.table-footer { margin: 12px 0 0; }.check-toolbar { justify-content: flex-start; }.check-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }.check-grid article { display: flex; align-items: center; gap: 9px; padding: 12px; background: var(--surface-muted); }.check-grid article > .el-icon { font-size: 18px; }.check-grid article > .ok { color: #17845a; }.check-grid article > .bad { color: #b4233e; }.check-grid article > div { min-width: 0; display: grid; gap: 4px; }.check-grid strong { color: var(--ink-900); font-size: 12px; }.check-grid small { overflow: hidden; color: var(--ink-500); font-size: 10px; text-overflow: ellipsis; white-space: nowrap; }
@media (max-width: 1200px) { .proxy-metrics { grid-template-columns: repeat(3, minmax(145px, 1fr)); }.runtime-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }.strategy-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
@media (max-width: 720px) { .proxy-heading { align-items: flex-start; flex-direction: column; }.proxy-metrics { grid-template-columns: repeat(2, minmax(0, 1fr)); }.runtime-grid, .strategy-grid, .check-grid { grid-template-columns: 1fr; }.node-toolbar { align-items: stretch; flex-direction: column; }.node-toolbar :deep(.el-input), .node-toolbar :deep(.el-select) { width: 100%; }.sub-toolbar, .check-toolbar { align-items: flex-start; flex-direction: column; }.action-row { width: 100%; }.action-row .el-button { flex: 1; }.proxy-collapse :deep(.el-collapse-item__header) { padding-inline: 12px; }.proxy-collapse :deep(.el-collapse-item__content) { padding-inline: 12px; } }
</style>
